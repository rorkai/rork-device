import Foundation

/// Client for the Apple File Conduit service.
///
/// AFC provides filesystem-style access to service-specific roots exposed by
/// the device. In the 0.1.0 install flow, this client is used to create
/// `/PublicStaging` and upload IPA archives before InstallationProxy installs
/// them.
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
        try await makeDirectory(AFCStaging.directory)
        try await removePath(stagedPath, ignoreMissing: true)
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
        try await makeDirectory(AFCStaging.directory)
        try await removePath(stagedPath, ignoreMissing: true)
        try await uploadFile(data, to: stagedPath)
        return stagedPath
    }

    /// Creates a directory in the AFC service root.
    public func makeDirectory(_ path: String) async throws {
        try await sendPathOperation(.makeDirectory, path: path)
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
        } catch RorkDeviceError.afcStatus(let status) where ignoreMissing && status == AFCStatus.noSuchFile {
            return
        }
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
                let chunk = try file.read(upToCount: AFCStaging.chunkSize) ?? Data()
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
                let end = min(offset + AFCStaging.chunkSize, data.count)
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

    /// Closes an AFC file handle.
    private func closeFile(_ handle: UInt64) async throws {
        var payload = Data()
        payload.appendLittleEndian(handle)
        try await sendPacket(operation: .fileClose, headerPayload: payload)
        _ = try await receiveStatus()
    }

    /// Encodes and sends one AFC packet.
    private func sendPacket(operation: AFCOperation, headerPayload: Data = Data(), bodyPayload: Data = Data()) async throws {
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
            throw RorkDeviceError.protocolViolation("Unexpected AFC packet number \(responsePacket), expected \(packetNumber).")
        }
        guard entireLength >= 40, thisLength >= 40, thisLength <= entireLength else {
            throw RorkDeviceError.protocolViolation("Invalid AFC packet lengths.")
        }

        let operationValue: UInt64 = try header.littleEndianInteger(at: 32)
        let payloadLength = Int(entireLength - 40)
        let payload = payloadLength == 0 ? Data() : try await connection.receive(exactly: payloadLength)
        return AFCPacketResponse(
            operation: AFCOperation(rawValue: operationValue) ?? .invalid,
            payload: payload
        )
    }

    /// Builds the safe `/PublicStaging` path used for one IPA upload.
    private func stagedIPAPath(bundleIdentifier: String) throws -> String {
        let filename = try AFCStaging.safeFilename(bundleIdentifier: bundleIdentifier)
        return "\(AFCStaging.directory)/\(filename).ipa"
    }
}

/// Constants and validation for AFC public staging uploads.
private enum AFCStaging {
    static let directory = "/PublicStaging"
    static let chunkSize = 64 * 1024
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
}

/// AFC magic bytes as they appear at the start of every packet.
private enum AFCMagic {
    static let bytes = Array("CFA6LPAA".utf8)
}

/// AFC operation codes used by the staging workflow.
private enum AFCOperation: UInt64 {
    case invalid = 0
    case status = 1
    case makeDirectory = 9
    case removePath = 8
    case fileOpen = 13
    case fileOpenResult = 14
    case fileWrite = 16
    case fileClose = 20
}

/// AFC file-open modes used by this package.
private enum AFCFileOpenMode: UInt64 {
    case writeOnly = 3
}

/// Decoded AFC packet response used internally by the client.
private struct AFCPacketResponse {
    let operation: AFCOperation
    let payload: Data
}
