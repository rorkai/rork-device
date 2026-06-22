import Foundation

/// Client for the Apple File Conduit service.
///
/// AFC provides filesystem-style access to service-specific roots exposed by
/// the device. The same protocol backs public staging during app installs and
/// HouseArrest container access for app documents and sandboxes.
///
/// An `AFCClient` owns one ordered AFC stream. Use one operation at a time per
/// client instance; create another service connection when a workflow needs
/// independent concurrent file operations.
public final class AFCClient {
    private let connection: DeviceConnection
    private var packetNumber: UInt64 = 0

    /// Creates an AFC client over an existing service connection.
    ///
    /// The connection should come from `DeviceSession.startService(.afc)` or a
    /// caller-provided transport that has already handled any required secure
    /// service upgrade.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Uploads an IPA into `/PublicStaging` and returns its device path.
    ///
    /// Existing staged files for the same bundle identifier are removed before
    /// upload so repeated installs do not reuse stale data.
    ///
    /// - Parameters:
    ///   - fileURL: Local IPA file.
    ///   - bundleIdentifier: Bundle identifier used to name the staged IPA.
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    public func uploadIPA(at fileURL: URL, bundleIdentifier: String) async throws -> String {
        let stagedPath = try stagedIPAPath(bundleIdentifier: bundleIdentifier)
        let stagedDirectory = try stagedDirectoryPath(bundleIdentifier: bundleIdentifier)
        try await makeDirectoryIfNeeded(AFCStaging.directory)
        try await removePath(stagedPath, ignoreMissing: true)
        try await makeDirectoryIfNeeded(stagedDirectory)
        try await uploadFile(at: fileURL, to: stagedPath)
        return stagedPath
    }

    /// Uploads in-memory IPA data into `/PublicStaging`.
    ///
    /// This variant is useful for apps and services that already hold an IPA
    /// archive in memory, for example after downloading or signing it. The
    /// bytes are written to the same device-side staging path as `uploadIPA(at:)`.
    ///
    /// - Parameters:
    ///   - data: IPA archive bytes.
    ///   - bundleIdentifier: Bundle identifier used to name the staged IPA.
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    public func uploadIPA(_ data: Data, bundleIdentifier: String) async throws -> String {
        let stagedPath = try stagedIPAPath(bundleIdentifier: bundleIdentifier)
        let stagedDirectory = try stagedDirectoryPath(bundleIdentifier: bundleIdentifier)
        try await makeDirectoryIfNeeded(AFCStaging.directory)
        try await removePath(stagedPath, ignoreMissing: true)
        try await makeDirectoryIfNeeded(stagedDirectory)
        try await uploadFile(data, to: stagedPath)
        return stagedPath
    }

    /// Creates a directory in the AFC service root.
    public func makeDirectory(_ path: String) async throws {
        try await sendPathOperation(.makeDirectory, path: path)
    }

    /// Lists entries in a directory.
    ///
    /// The returned names exclude empty trailing fields from the AFC payload but
    /// otherwise preserve the device response. Callers can decide whether to
    /// filter `"."` and `".."` for their own UI.
    ///
    /// - Parameter path: Directory path in the AFC service root.
    /// - Returns: Entry names reported by the service.
    public func directoryContents(at path: String) async throws -> [String] {
        let response = try await sendDataPathOperation(.readDirectory, path: path)
        return decodeNullTerminatedStrings(response.payload)
    }

    /// Reads metadata for a path in the AFC service root.
    ///
    /// AFC reports metadata as string key/value pairs. `AFCFileInfo` keeps the
    /// original values and exposes common fields such as type and size.
    ///
    /// - Parameter path: File or directory path in the AFC service root.
    /// - Returns: Parsed file metadata.
    public func fileInfo(at path: String) async throws -> AFCFileInfo {
        let response = try await sendDataPathOperation(.getFileInfo, path: path)
        return AFCFileInfo(values: decodeNullTerminatedKeyValuePairs(response.payload))
    }

    /// Creates a directory if it does not already exist.
    private func makeDirectoryIfNeeded(_ path: String) async throws {
        do {
            try await makeDirectory(path)
        } catch RorkDeviceError.afcStatus(let status) where status == AFCStatus.objectExists {
            return
        }
    }

    /// Removes a file or directory in the AFC service root.
    ///
    /// - Parameters:
    ///   - path: AFC path to remove.
    ///   - ignoreMissing: When true, a missing path is ignored so callers can
    ///     implement idempotent cleanup. Other AFC errors are still thrown.
    public func removePath(_ path: String, ignoreMissing: Bool = false) async throws {
        do {
            try await sendPathOperation(.removePath, path: path)
        } catch RorkDeviceError.afcStatus(let status)
            where ignoreMissing && status == AFCStatus.noSuchFile
        {
            return
        }
    }

    /// Moves or renames a path in the AFC service root.
    ///
    /// - Parameters:
    ///   - sourcePath: Existing path.
    ///   - destinationPath: New path.
    public func movePath(from sourcePath: String, to destinationPath: String) async throws {
        var payload = Data(sourcePath.utf8)
        payload.append(0)
        payload.append(contentsOf: destinationPath.utf8)
        payload.append(0)
        try await sendPacket(operation: .renamePath, headerPayload: payload)
        _ = try await receiveStatus()
    }

    /// Reads a remote file into memory.
    ///
    /// Use `downloadFile(from:to:)` for large files when writing directly to
    /// disk is preferable.
    ///
    /// - Parameter path: Remote file path in the AFC service root.
    /// - Returns: File contents.
    public func contentsOfFile(at path: String) async throws -> Data {
        let handle = try await openFile(path, mode: .readOnly)
        var contents = Data()
        do {
            while true {
                let chunk = try await read(handle: handle, length: AFCStaging.readChunkSize)
                if chunk.isEmpty {
                    break
                }
                contents.append(chunk)
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
        return contents
    }

    /// Downloads a remote file to a local URL.
    ///
    /// - Parameters:
    ///   - remotePath: File path in the AFC service root.
    ///   - localURL: Destination file URL on the host.
    public func downloadFile(from remotePath: String, to localURL: URL) async throws {
        let handle = try await openFile(remotePath, mode: .readOnly)
        do {
            _ = FileManager.default.createFile(
                atPath: localURL.path,
                contents: nil
            )
            let file = try FileHandle(forWritingTo: localURL)
            defer { try? file.close() }
            try file.truncate(atOffset: 0)

            while true {
                let chunk = try await read(handle: handle, length: AFCStaging.readChunkSize)
                if chunk.isEmpty {
                    break
                }
                try file.write(contentsOf: chunk)
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
    }

    /// Uploads a local file to a remote AFC path.
    ///
    /// The file is streamed in fixed-size chunks so callers can stage large
    /// archives without needing a service-specific helper.
    /// - Parameters:
    ///   - fileURL: Local file to stream into AFC.
    ///   - destinationPath: Destination path in the AFC service root.
    public func uploadFile(at fileURL: URL, to destinationPath: String) async throws {
        let handle = try await openFile(destinationPath, mode: .writeOnly)
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            while true {
                let chunk = try file.read(upToCount: AFCStaging.writeChunkSize) ?? Data()
                if chunk.isEmpty {
                    break
                }
                try await write(handle: handle, data: chunk[...])
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
    }

    /// Uploads data to a remote AFC path.
    ///
    /// The payload is streamed in fixed-size chunks to match the behavior of
    /// `uploadFile(at:to:)` while avoiding temporary files in
    /// callers that already own the bytes.
    ///
    /// - Parameters:
    ///   - data: Bytes to stream into AFC.
    ///   - destinationPath: Destination path in the AFC service root.
    public func uploadFile(_ data: Data, to destinationPath: String) async throws {
        let handle = try await openFile(destinationPath, mode: .writeOnly)
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + AFCStaging.writeChunkSize, data.count)
                try await write(handle: handle, data: data[offset..<end])
                offset = end
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
    }

    /// Sends a path-only AFC command and validates its status response.
    private func sendPathOperation(_ operation: AFCOperation, path: String) async throws {
        var payload = Data(path.utf8)
        payload.append(0)
        try await sendPacket(operation: operation, headerPayload: payload)
        _ = try await receiveStatus()
    }

    /// Sends a path command that should return an AFC data payload.
    private func sendDataPathOperation(_ operation: AFCOperation, path: String) async throws
        -> AFCPacketResponse
    {
        var payload = Data(path.utf8)
        payload.append(0)
        try await sendPacket(operation: operation, headerPayload: payload)
        let response = try await receivePacket()
        if response.operation == .data {
            return response
        }
        try handleStatus(response)
        throw RorkDeviceError.protocolViolation("AFC response did not contain data.")
    }

    /// Opens a remote file and returns the AFC file handle.
    private func openFile(_ path: String, mode: AFCFileOpenMode) async throws -> UInt64 {
        var payload = Data()
        payload.appendLittleEndian(mode.rawValue)
        payload.append(contentsOf: path.utf8)
        payload.append(0)
        try await sendPacket(operation: .fileOpen, headerPayload: payload)
        let response = try await receivePacket()
        guard response.operation == .fileOpenResult, response.payload.count >= 8 else {
            try handleStatus(response)
            throw RorkDeviceError.protocolViolation("AFC file open did not return a file handle.")
        }
        return try response.payload.littleEndianInteger(at: 0, as: UInt64.self)
    }

    /// Writes one chunk to an open AFC file handle.
    private func write(handle: UInt64, data: Data.SubSequence) async throws {
        var header = Data()
        header.appendLittleEndian(handle)
        try await sendPacket(operation: .fileWrite, headerPayload: header, bodyPayload: Data(data))
        _ = try await receiveStatus()
    }

    /// Reads one chunk from an open AFC file handle.
    private func read(handle: UInt64, length: Int) async throws -> Data {
        var header = Data()
        header.appendLittleEndian(handle)
        header.appendLittleEndian(UInt64(length))
        try await sendPacket(operation: .fileRead, headerPayload: header)
        let response = try await receivePacket()
        if response.operation == .data {
            return response.payload
        }
        try handleStatus(response)
        throw RorkDeviceError.protocolViolation("AFC file read did not return data.")
    }

    /// Closes an AFC file handle.
    private func closeFile(_ handle: UInt64) async throws {
        var payload = Data()
        payload.appendLittleEndian(handle)
        try await sendPacket(operation: .fileClose, headerPayload: payload)
        _ = try await receiveStatus()
    }

    /// Encodes and sends one AFC packet.
    private func sendPacket(
        operation: AFCOperation, headerPayload: Data = Data(), bodyPayload: Data = Data()
    ) async throws {
        packetNumber += 1
        let thisLength = UInt64(40 + headerPayload.count)
        let entireLength = UInt64(40 + headerPayload.count + bodyPayload.count)
        var packet = Data()
        packet.append(contentsOf: AFCMagic.bytes)
        packet.appendLittleEndian(entireLength)
        packet.appendLittleEndian(thisLength)
        packet.appendLittleEndian(packetNumber)
        packet.appendLittleEndian(operation.rawValue)
        packet.append(headerPayload)
        packet.append(bodyPayload)
        try await connection.send(packet)
    }

    /// Receives an AFC status packet and returns the numeric status value.
    private func receiveStatus() async throws -> UInt64 {
        let response = try await receivePacket()
        guard response.operation == .status else {
            throw RorkDeviceError.protocolViolation("AFC response was not a status packet.")
        }
        guard response.payload.count >= 8 else {
            throw RorkDeviceError.protocolViolation("AFC status packet was truncated.")
        }
        let status = try response.payload.littleEndianInteger(at: 0, as: UInt64.self)
        if status != 0 {
            throw RorkDeviceError.afcStatus(status)
        }
        return status
    }

    /// Throws when a response is an AFC status packet with a non-zero status.
    private func handleStatus(_ response: AFCPacketResponse) throws {
        if response.operation == .status {
            guard response.payload.count >= 8 else {
                throw RorkDeviceError.protocolViolation("AFC status packet was truncated.")
            }
            let status = try response.payload.littleEndianInteger(at: 0, as: UInt64.self)
            if status != 0 {
                throw RorkDeviceError.afcStatus(status)
            }
        }
    }

    /// Receives and validates one AFC packet.
    private func receivePacket() async throws -> AFCPacketResponse {
        let header = try await connection.receive(exactly: 40)
        guard header.prefix(8) == Data(AFCMagic.bytes) else {
            throw RorkDeviceError.protocolViolation("Invalid AFC magic.")
        }

        let entireLength: UInt64 = try header.littleEndianInteger(at: 8)
        let thisLength: UInt64 = try header.littleEndianInteger(at: 16)
        let responsePacket: UInt64 = try header.littleEndianInteger(at: 24)
        guard responsePacket == packetNumber else {
            throw RorkDeviceError.protocolViolation(
                "Unexpected AFC packet number \(responsePacket), expected \(packetNumber).")
        }
        guard entireLength >= 40, thisLength >= 40, thisLength <= entireLength else {
            throw RorkDeviceError.protocolViolation("Invalid AFC packet lengths.")
        }

        let operationValue: UInt64 = try header.littleEndianInteger(at: 32)
        let rawPayloadLength = entireLength - 40
        guard rawPayloadLength <= UInt64(Int.max) else {
            throw RorkDeviceError.protocolViolation(
                "AFC payload length exceeds host limits."
            )
        }
        let payloadLength = Int(rawPayloadLength)
        let payload =
            payloadLength == 0 ? Data() : try await connection.receive(exactly: payloadLength)
        return AFCPacketResponse(
            operation: AFCOperation(rawValue: operationValue) ?? .invalid,
            payload: payload
        )
    }

    /// Builds the safe `./PublicStaging/<bundle>` directory for one IPA upload.
    private func stagedDirectoryPath(bundleIdentifier: String) throws -> String {
        let filename = try AFCStaging.safeFilename(bundleIdentifier: bundleIdentifier)
        return "\(AFCStaging.directory)/\(filename)"
    }

    /// Builds the safe `./PublicStaging/<bundle>/app.ipa` path used for one IPA upload.
    private func stagedIPAPath(bundleIdentifier: String) throws -> String {
        "\(try stagedDirectoryPath(bundleIdentifier: bundleIdentifier))/app.ipa"
    }
}

/// Constants and validation for AFC public staging uploads.
private enum AFCStaging {
    static let directory = "./PublicStaging"

    /// Keeps ordinary file reads bounded without requesting unusually large
    /// responses from services that may produce data incrementally.
    static let readChunkSize = 64 * 1024

    /// Amortizes AFC's mandatory status response across enough staged data to
    /// avoid hundreds of round trips for a typical IPA. The underlying
    /// transport remains responsible for segmenting the request into packets
    /// that fit its framing and flow-control limits.
    static let writeChunkSize = 1024 * 1024

    static let maxFilenameLength = 255

    static func safeFilename(bundleIdentifier: String) throws -> String {
        let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw RorkDeviceError.invalidInput("Bundle identifier is empty.")
        }
        guard value.utf8.count <= maxFilenameLength else {
            throw RorkDeviceError.invalidInput("Bundle identifier is too long for AFC staging.")
        }
        guard !value.contains("/"), !value.contains("\\"), !value.contains("..") else {
            throw RorkDeviceError.invalidInput("Bundle identifier is not safe for AFC staging.")
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RorkDeviceError.invalidInput("Bundle identifier contains unsupported characters.")
        }
        return value
    }
}

/// AFC status values used by the high-level staging workflow.
private enum AFCStatus {
    static let noSuchFile: UInt64 = 8
    static let objectExists: UInt64 = 16
}

/// AFC magic bytes as they appear at the start of every packet.
private enum AFCMagic {
    static let bytes = Array("CFA6LPAA".utf8)
}

/// AFC operation codes used by the staging workflow.
private enum AFCOperation: UInt64 {
    case invalid = 0
    case status = 1
    case data = 2
    case readDirectory = 3
    case makeDirectory = 9
    case removePath = 8
    case getFileInfo = 10
    case fileOpen = 13
    case fileOpenResult = 14
    case fileRead = 15
    case fileWrite = 16
    case fileClose = 20
    case renamePath = 24
}

/// AFC file-open modes used by this package.
private enum AFCFileOpenMode: UInt64 {
    case readOnly = 1
    case writeOnly = 3
}

/// Decoded AFC packet response used internally by the client.
private struct AFCPacketResponse {
    let operation: AFCOperation
    let payload: Data
}

/// File type reported by AFC metadata.
public struct AFCItemType: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible
{
    /// Raw `st_ifmt` value reported by AFC.
    public let rawValue: String

    /// Creates a file type from a raw AFC `st_ifmt` value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Regular file.
    public static let regularFile = AFCItemType(rawValue: "S_IFREG")

    /// Directory.
    public static let directory = AFCItemType(rawValue: "S_IFDIR")

    /// Symbolic link.
    public static let symbolicLink = AFCItemType(rawValue: "S_IFLNK")

    /// Printable description used by CLI output.
    public var description: String {
        rawValue
    }
}

/// Metadata returned by AFC for one file-system item.
public struct AFCFileInfo: Equatable, Sendable {
    /// Raw metadata values keyed by AFC field name.
    public let values: [String: String]

    /// File type derived from `st_ifmt` when present.
    public var type: AFCItemType? {
        values["st_ifmt"].map(AFCItemType.init(rawValue:))
    }

    /// File size in bytes derived from `st_size` when present.
    public var size: UInt64? {
        values["st_size"].flatMap(UInt64.init)
    }

    /// Link target reported by AFC for symbolic links.
    public var linkTarget: String? {
        values["LinkTarget"]
    }

    /// Creates metadata from raw AFC key/value fields.
    public init(values: [String: String]) {
        self.values = values
    }
}

/// Splits AFC NUL-terminated string payloads into fields.
private func decodeNullTerminatedStrings(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
}

/// Parses AFC metadata payloads encoded as alternating key/value fields.
private func decodeNullTerminatedKeyValuePairs(_ data: Data) -> [String: String] {
    let fields = decodeNullTerminatedStrings(data)
    var values: [String: String] = [:]
    var index = 0
    while index + 1 < fields.count {
        values[fields[index]] = fields[index + 1]
        index += 2
    }
    return values
}
