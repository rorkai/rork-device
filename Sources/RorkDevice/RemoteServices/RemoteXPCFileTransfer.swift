import Foundation

/// Bytes uploaded through one RemoteXPC file transfer.
enum RemoteXPCUploadPayload {
    /// Payload already held in memory, such as a personalization ticket.
    case data(Data)

    /// File streamed from disk so large images are never loaded whole.
    case file(URL)

    /// Returns the byte count announced in the transfer object.
    func size() throws -> UInt64 {
        switch self {
        case let .data(data):
            return UInt64(data.count)
        case .file:
            let reader = try openReader()
            defer {
                reader.close()
            }
            return reader.size
        }
    }

    /// Opens a sequential reader positioned at the first byte.
    func openReader() throws -> RemoteXPCUploadReader {
        switch self {
        case let .data(data):
            return RemoteXPCUploadReader(data: data)
        case let .file(url):
            return try RemoteXPCUploadReader(fileURL: url)
        }
    }
}

/// Sequential reader over one upload payload.
final class RemoteXPCUploadReader {
    /// Total bytes the payload holds.
    let size: UInt64

    /// File handle for file payloads, or `nil` for in-memory data.
    private let handle: FileHandle?

    /// Remaining in-memory bytes for data payloads.
    private var remainingData: Data

    /// Creates a reader over in-memory bytes.
    init(data: Data) {
        size = UInt64(data.count)
        handle = nil
        remainingData = data
    }

    /// Opens a file and records its size.
    init(fileURL: URL) throws {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            do {
                size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
            } catch {
                try? handle.close()
                throw error
            }
            self.handle = handle
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not read \(fileURL.lastPathComponent) for upload: \(error.localizedDescription)"
            )
        }
        remainingData = Data()
    }

    /// Reads up to `count` bytes, returning fewer only at the end.
    func read(upToCount count: Int) throws -> Data {
        guard let handle else {
            let chunk = remainingData.prefix(count)
            remainingData = Data(remainingData.dropFirst(chunk.count))
            return Data(chunk)
        }
        do {
            var chunk = Data()
            while chunk.count < count,
                  let next = try handle.read(upToCount: count - chunk.count),
                  !next.isEmpty
            {
                chunk.append(next)
            }
            return chunk
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not read upload payload: \(error.localizedDescription)"
            )
        }
    }

    /// Releases the file handle, if any.
    func close() {
        try? handle?.close()
    }
}

/// Peer flow-control windows for the streams a RemoteXPC connection uploads on.
///
/// HTTP/2 lets the receiver bound how much unacknowledged DATA a sender may
/// have in flight, per stream and for the whole connection (RFC 9113 6.9).
/// Uploads larger than the peer's initial window must wait for its
/// WINDOW_UPDATE frames, while short control messages never come near the
/// limit and only count against the connection window.
struct RemoteXPCSendFlowControl {
    /// Send window every newly opened stream starts with.
    private var initialWindowSize: Int64

    /// Largest DATA payload the peer accepts in one frame.
    private var maximumFrameSize: Int

    /// Bytes the connection may still send before the peer grants more.
    private var connectionWindow: Int64

    /// Bytes each open file-transfer stream may still send.
    private var streamWindows: [UInt32: Int64] = [:]

    /// File-transfer streams whose uploads have ended, kept so late resets
    /// and acknowledgements on them are recognized.
    private var finishedStreams: Set<UInt32> = []

    /// Error codes of file-transfer streams the peer reset.
    private var resetStreams: [UInt32: UInt32] = [:]

    /// Identifier the next host-initiated stream receives. Streams 1 and 3
    /// are the fixed RemoteXPC streams.
    private var nextStreamIdentifier: UInt32 = 5

    /// Creates the state that applies before the peer's SETTINGS arrive.
    init(initialWindowSize: Int64, maximumFrameSize: Int) {
        self.initialWindowSize = initialWindowSize
        self.maximumFrameSize = maximumFrameSize
        connectionWindow = initialWindowSize
    }

    /// Allocates a new file-transfer stream with the peer's initial window.
    mutating func openStream() -> UInt32 {
        let identifier = nextStreamIdentifier
        nextStreamIdentifier += 2
        streamWindows[identifier] = initialWindowSize
        return identifier
    }

    /// Whether DATA or a reset on the stream belongs to a file transfer.
    func isFileTransferStream(_ identifier: UInt32) -> Bool {
        streamWindows[identifier] != nil || finishedStreams.contains(identifier)
    }

    /// Throws when the peer has reset an upload stream.
    func requireOpen(_ identifier: UInt32) throws {
        if let errorCode = resetStreams[identifier] {
            throw RorkDeviceError.remoteXPCStreamReset(
                streamIdentifier: identifier,
                errorCode: errorCode
            )
        }
    }

    /// Reserves up to `count` bytes of both windows for one DATA frame.
    ///
    /// - Returns: The bytes that may be sent now, or zero when the caller must
    ///   wait for a WINDOW_UPDATE.
    mutating func reserve(upTo count: Int, on identifier: UInt32) throws -> Int {
        try requireOpen(identifier)
        guard let streamWindow = streamWindows[identifier] else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC stream \(identifier) is not an open file transfer."
            )
        }
        let allowance = min(
            Int64(count),
            Int64(maximumFrameSize),
            streamWindow,
            connectionWindow
        )
        guard allowance > 0 else {
            return 0
        }
        streamWindows[identifier] = streamWindow - allowance
        connectionWindow -= allowance
        return Int(allowance)
    }

    /// Charges DATA sent outside an upload against the connection window.
    mutating func charge(_ count: Int) {
        connectionWindow -= Int64(count)
    }

    /// Marks an upload stream as fully sent.
    mutating func finish(_ identifier: UInt32) {
        streamWindows[identifier] = nil
        finishedStreams.insert(identifier)
    }

    /// Records a reset and reports whether it belongs to a file transfer.
    mutating func reset(_ identifier: UInt32, errorCode: UInt32) -> Bool {
        guard isFileTransferStream(identifier) else {
            return false
        }
        if streamWindows[identifier] != nil {
            resetStreams[identifier] = errorCode
        }
        return true
    }

    /// Applies a WINDOW_UPDATE to the connection or one upload stream.
    mutating func grant(_ increment: Int64, on identifier: UInt32) {
        if identifier == 0 {
            connectionWindow += increment
        } else if let window = streamWindows[identifier] {
            streamWindows[identifier] = window + increment
        }
    }

    /// Applies the peer's SETTINGS payload.
    ///
    /// A new initial window size shifts every open stream window by the
    /// difference (RFC 9113 6.9.2).
    mutating func apply(settings payload: Data) throws {
        guard payload.count % 6 == 0 else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC HTTP/2 SETTINGS payload length \(payload.count) is not a multiple of six."
            )
        }
        var offset = 0
        while offset < payload.count {
            let identifier: UInt16 = try payload.bigEndianInteger(at: offset)
            let value: UInt32 = try payload.bigEndianInteger(at: offset + 2)
            offset += 6
            switch identifier {
            case 0x4:
                let delta = Int64(value) - initialWindowSize
                initialWindowSize = Int64(value)
                for (stream, window) in streamWindows {
                    streamWindows[stream] = window + delta
                }
            case 0x5:
                maximumFrameSize = Int(value)
            default:
                continue
            }
        }
    }
}
