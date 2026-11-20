import Foundation

/// Bidirectional RemoteXPC session carried over the device's HTTP/2 transport.
///
/// Apple services exposed through Remote Service Discovery use two fixed HTTP/2
/// streams. The host writes requests on the control stream, while services may
/// return feature responses on the device-initiated reply stream. Session
/// startup exchanges acknowledgements on both streams before either becomes
/// available to service-specific code.
///
/// Requests that carry file transfers send each payload on an extra
/// host-initiated stream, honoring the peer's HTTP/2 flow-control windows.
///
/// Callers may send from multiple tasks while one task owns the receive path.
/// A lock protects message and receive state, and an actor serializes complete
/// HTTP/2 writes. Instances only wrap package-owned connections whose send,
/// receive, and close implementations support that full-duplex access pattern.
final class RemoteXPCConnection: @unchecked Sendable {
    /// Logical RemoteXPC streams and their fixed HTTP/2 identifiers.
    enum Stream {
        /// Host-initiated requests and their corresponding responses.
        case control

        /// Device-initiated replies and asynchronous messages.
        case reply

        /// HTTP/2 stream identifier assigned by the RemoteXPC protocol.
        fileprivate var identifier: UInt32 {
            switch self {
            case .control:
                return 1
            case .reply:
                return 3
            }
        }
    }

    /// HTTP/2 frame types required by RemoteXPC.
    private enum FrameType: UInt8 {
        /// Carries RemoteXPC wrapper bytes.
        case data = 0x00

        /// Opens one of the protocol's fixed streams.
        case headers = 0x01

        /// Reports that the peer terminated a stream.
        case streamReset = 0x03

        /// Exchanges HTTP/2 connection settings.
        case settings = 0x04

        /// Keeps the HTTP/2 connection responsive.
        case ping = 0x06

        /// Reports connection-wide shutdown.
        case goAway = 0x07

        /// Expands the HTTP/2 flow-control window.
        case windowUpdate = 0x08
    }

    /// Decoded HTTP/2 frame after optional DATA padding is removed.
    private struct Frame {
        /// Raw frame type so unknown values can be ignored safely.
        let type: UInt8

        /// HTTP/2 flags supplied by the peer.
        let flags: UInt8

        /// Stream identifier with the reserved bit removed.
        let streamIdentifier: UInt32

        /// Frame payload after protocol-level padding is removed.
        let payload: Data
    }

    /// HTTP/2 client connection preface required before the first frame.
    private static let clientPreface = Data(
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8
    )

    /// HTTP/2 flag indicating that a HEADERS block is complete.
    private static let endHeadersFlag: UInt8 = 0x04

    /// Shared acknowledgement flag used by SETTINGS and PING.
    private static let acknowledgementFlag: UInt8 = 0x01

    /// RemoteXPC wrapper flag present on every application message.
    private static let alwaysSetFlag: UInt32 = 0x00000001

    /// RemoteXPC wrapper flag indicating that a message contains an object body.
    private static let dataFlag: UInt32 = 0x00000100

    /// RemoteXPC wrapper flag used to initialize the reply stream.
    private static let initializeReplyStreamFlag: UInt32 = 0x00400000

    /// RemoteXPC wrapper flag announcing the transfer a new stream carries.
    private static let fileOpenFlag: UInt32 = 0x00100000

    /// RemoteXPC wrapper flag the peer uses to accept a file transfer.
    private static let fileOpenReplyFlag: UInt32 = 0x00200000

    /// HTTP/2 flag ending the sender's half of a stream.
    private static let endStreamFlag: UInt8 = 0x01

    /// HTTP/2 flow-control window that applies until the peer's SETTINGS.
    private static let defaultWindowSize: Int64 = 65_535

    /// HTTP/2 DATA frame size limit that applies until the peer's SETTINGS.
    private static let defaultMaximumFrameSize = 16_384

    /// Connected byte stream carrying the HTTP/2 session.
    private let connection: DeviceConnection

    /// Coordinates complete HTTP/2 frame writes on the underlying byte stream.
    private let writeCoordinator = RemoteXPCWriteCoordinator()

    /// Protects message-identifier allocation and receive-operation ownership.
    private let stateLock = NSLock()

    /// Incomplete RemoteXPC bytes accumulated independently for each stream.
    private var streamBuffers: [UInt32: Data] = [:]

    /// Identifier assigned to the next application-level message.
    private var nextMessageIdentifier: UInt64 = 1

    /// Whether one task currently owns frame reads and stream buffers.
    private var isReceiving = false

    /// Whether an upload stopped with transfer streams the host opened but
    /// never ended, which leaves their stream accounting unknown.
    private var hasUnfinishedUpload = false

    /// Flow-control state for payloads sent on file-transfer streams.
    private var flowControl = RemoteXPCSendFlowControl(
        initialWindowSize: defaultWindowSize,
        maximumFrameSize: defaultMaximumFrameSize
    )

    /// Creates a protocol driver without starting the RemoteXPC handshake.
    private init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Opens the HTTP/2 streams and sends the RemoteXPC channel handshake.
    ///
    /// The returned instance owns the supplied connection. Call `close()` when
    /// the advertised service ports or the RemoteXPC service are no longer
    /// needed.
    static func open(
        over connection: DeviceConnection
    ) async throws -> RemoteXPCConnection {
        let remoteXPC = RemoteXPCConnection(connection: connection)
        do {
            try await remoteXPC.startSession()
            return remoteXPC
        } catch {
            connection.close()
            throw error
        }
    }

    /// Sends one application value on the control stream.
    ///
    /// Message identifiers begin at one after the channel handshake. A nonempty
    /// value automatically receives both the required always-set and data flags.
    func send(
        _ value: RemoteXPCValue?,
        additionalFlags: UInt32 = 0
    ) async throws {
        let messageIdentifier = stateLock.withLock {
            let identifier = nextMessageIdentifier
            nextMessageIdentifier &+= 1
            return identifier
        }
        let flags = Self.alwaysSetFlag
            | (value == nil ? 0 : Self.dataFlag)
            | additionalFlags
        try await send(
            value,
            flags: flags,
            messageIdentifier: messageIdentifier,
            on: .control
        )
    }

    /// Receives the next complete message from one logical stream.
    ///
    /// DATA frames for the other stream remain buffered, allowing callers to
    /// consume asynchronous replies later without losing bytes while waiting on
    /// the control stream.
    func receive(
        on stream: Stream = .control
    ) async throws -> RemoteXPCMessage {
        try beginReceiving()
        defer {
            endReceiving()
        }

        while true {
            if let decoded = try decodeBufferedMessage(on: stream.identifier) {
                return decoded
            }
            try await process(receiveFrame())
        }
    }

    /// Sends one request on the control stream once the peer's windows
    /// allow it.
    ///
    /// Unlike `send(_:additionalFlags:)`, which other tasks may call while a
    /// receive is in progress and which charges its frames after writing
    /// them, this method waits for WINDOW_UPDATE by reading frames. It owns
    /// the receive path and must not overlap a `receive`.
    func sendWithinWindows(
        _ value: RemoteXPCValue,
        additionalFlags: UInt32 = 0
    ) async throws {
        try await send(uploading: [], additionalFlags: additionalFlags) { _ in
            value
        }
    }

    /// Sends a request whose file transfers carry the supplied payloads.
    ///
    /// The request receives the next message identifier and its transfers the
    /// identifiers after it, the layout CoreDevice uses for cryptexd installs.
    /// Each payload is announced on its own stream before the request is sent,
    /// then uploaded once the peer accepts that stream. The method returns
    /// after every payload has been sent, or as soon as a reply waits on the
    /// reply stream, since a service that answers mid-upload has refused the
    /// request and will accept no more of it. Read that reply with
    /// `receive(on: .reply)`. Waiting for acceptances and window updates
    /// reads frames, so the method owns the receive path and must not overlap
    /// a `receive`.
    ///
    /// - Parameters:
    ///   - payloads: Payload sources in the order their transfers are listed.
    ///   - additionalFlags: Wrapper flags added to the request message.
    ///   - makeRequest: Builds the request from one `.fileTransfer` value per
    ///     payload, in the same order.
    /// - Returns: Whether every payload was sent or the peer answered first.
    /// An upload that stops before every stream is ended leaves those
    /// streams open, so later uploads on the connection are refused. Open a
    /// new connection instead.
    ///
    /// - Throws: An input error when a payload cannot be read, a stream-reset
    ///   error when the peer abandons a transfer, a protocol error when the
    ///   peer ends a transfer stream without accepting it or allows too few
    ///   concurrent streams, or when an earlier upload did not finish, or
    ///   transport errors.
    @discardableResult
    func send(
        uploading payloads: [RemoteXPCUploadPayload],
        additionalFlags: UInt32 = 0,
        makeRequest: ([RemoteXPCValue]) throws -> RemoteXPCValue
    ) async throws -> RemoteXPCUploadOutcome {
        try beginReceiving()
        defer {
            endReceiving()
        }

        let sizes = try payloads.map { try $0.size() }
        try stateLock.withLock {
            guard !hasUnfinishedUpload else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC connection has file-transfer streams an earlier upload left open."
                )
            }
            try flowControl.requireCapacity(forFileTransfers: payloads.count)
        }
        let requestIdentifier = stateLock.withLock {
            let identifier = nextMessageIdentifier
            nextMessageIdentifier &+= UInt64(payloads.count) + 1
            return identifier
        }
        let transferIdentifiers = sizes.indices.map {
            requestIdentifier + UInt64($0) + 1
        }
        let request = try makeRequest(
            zip(transferIdentifiers, sizes).map {
                .fileTransfer(identifier: $0, size: $1)
            }
        )

        var isFinished = false
        defer {
            if !isFinished {
                stateLock.withLock {
                    hasUnfinishedUpload = true
                }
            }
        }
        var transfers: [(identifier: UInt64, size: UInt64, stream: UInt32)] = []
        for (identifier, size) in zip(transferIdentifiers, sizes) {
            // A SETTINGS frame read while an earlier file-open message waited
            // for credit may have lowered the peer's stream limit.
            let stream = try stateLock.withLock {
                try flowControl.requireCapacity(forFileTransfers: 1)
                return flowControl.openStream()
            }
            transfers.append((identifier, size, stream))
            try await sendFrame(
                type: .headers,
                flags: Self.endHeadersFlag,
                streamIdentifier: stream
            )
            try await sendWithinWindows(
                RemoteXPCMessageCodec.encode(
                    value: nil,
                    flags: Self.alwaysSetFlag | Self.fileOpenFlag,
                    messageIdentifier: identifier
                ),
                on: stream
            )
        }
        try await sendWithinWindows(
            RemoteXPCMessageCodec.encode(
                value: request,
                flags: Self.alwaysSetFlag | Self.dataFlag | additionalFlags,
                messageIdentifier: requestIdentifier
            ),
            on: Stream.control.identifier
        )

        for (transfer, payload) in zip(transfers, payloads) {
            guard try await waitForAcceptance(
                of: transfer.identifier,
                on: transfer.stream
            ), try await upload(
                payload,
                size: transfer.size,
                on: transfer.stream
            ) else {
                return .answeredBeforeUploadFinished
            }
        }
        isFinished = true
        return .uploaded
    }

    /// Sends a RemoteXPC message in DATA frames the peer's windows and frame
    /// size allow, reading frames while it waits for WINDOW_UPDATE.
    ///
    /// A message that fits goes out as one frame. Only a caller that owns the
    /// receive path may wait like this, so other sends keep charging their
    /// frames after writing them.
    private func sendWithinWindows(
        _ payload: Data,
        on streamIdentifier: UInt32
    ) async throws {
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let allowance = try stateLock.withLock {
                try flowControl.reserve(
                    upTo: payload.endIndex - offset,
                    on: streamIdentifier
                )
            }
            guard allowance > 0 else {
                // A transfer the peer ended before its file-open message was
                // complete can no longer be accepted.
                let isEnded = stateLock.withLock {
                    flowControl.isEndedByPeer(streamIdentifier)
                }
                guard !isEnded else {
                    throw RorkDeviceError.protocolViolation(
                        "RemoteXPC stream \(streamIdentifier) ended before its message was sent."
                    )
                }
                try await process(receiveFrame())
                continue
            }
            try await sendFrame(
                type: .data,
                streamIdentifier: streamIdentifier,
                payload: payload.subdata(in: offset..<(offset + allowance)),
                isFlowControlled: false
            )
            offset += allowance
        }
    }

    /// Reads frames until the peer accepts the transfer announced on a stream.
    ///
    /// - Returns: `false` when a reply arrived before the acceptance.
    private func waitForAcceptance(
        of transferIdentifier: UInt64,
        on streamIdentifier: UInt32
    ) async throws -> Bool {
        while true {
            if let message = try decodeBufferedMessage(on: streamIdentifier) {
                guard message.flags & Self.fileOpenReplyFlag != 0,
                      message.messageIdentifier == transferIdentifier else {
                    throw RorkDeviceError.protocolViolation(
                        "RemoteXPC file transfer \(transferIdentifier) received flags 0x\(String(message.flags, radix: 16)) for message \(message.messageIdentifier) instead of its acceptance."
                    )
                }
                return true
            }
            let isEnded = try stateLock.withLock {
                try flowControl.requireOpen(streamIdentifier)
                return flowControl.isEndedByPeer(streamIdentifier)
            }
            guard !isEnded else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC file transfer \(transferIdentifier) ended on stream \(streamIdentifier) before the peer accepted it."
                )
            }
            // Any message on the reply stream counts as the routine's
            // answer. The connection carries one request, and it does not set
            // `enable-install-events`, the install key in macOS 27's
            // libcryptex_interface that asks cryptexd for progress messages
            // (2026-11-20).
            if try hasBufferedMessage(on: Stream.reply.identifier) {
                return false
            }
            try await process(receiveFrame())
        }
    }

    /// Sends one payload in DATA frames the peer's windows allow, then ends
    /// the stream.
    ///
    /// - Returns: `false` when a reply arrived while the upload waited for
    ///   window credit.
    private func upload(
        _ payload: RemoteXPCUploadPayload,
        size: UInt64,
        on streamIdentifier: UInt32
    ) async throws -> Bool {
        let reader = try payload.openReader()
        defer {
            reader.close()
        }
        var remaining = size
        while remaining > 0 {
            let allowance = try stateLock.withLock {
                try flowControl.reserve(
                    upTo: Int(clamping: remaining),
                    on: streamIdentifier
                )
            }
            guard allowance > 0 else {
                if try hasBufferedMessage(on: Stream.reply.identifier) {
                    return false
                }
                try await process(receiveFrame())
                continue
            }
            let chunk = try reader.read(upToCount: allowance)
            guard chunk.count == allowance else {
                throw RorkDeviceError.invalidInput(
                    "A RemoteXPC upload ended before its announced \(size) bytes."
                )
            }
            try await sendFrame(
                type: .data,
                streamIdentifier: streamIdentifier,
                payload: chunk,
                isFlowControlled: false
            )
            remaining -= UInt64(allowance)
        }
        try await sendFrame(
            type: .data,
            flags: Self.endStreamFlag,
            streamIdentifier: streamIdentifier
        )
        stateLock.withLock {
            flowControl.finish(streamIdentifier)
        }
        return true
    }

    /// Applies one received frame to stream buffers and connection state.
    private func process(_ frame: Frame) async throws {
        switch FrameType(rawValue: frame.type) {
        case .data:
            let isFileTransferStream = stateLock.withLock {
                flowControl.isFileTransferStream(frame.streamIdentifier)
            }
            guard frame.streamIdentifier == Stream.control.identifier
                    || frame.streamIdentifier == Stream.reply.identifier
                    || isFileTransferStream else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC received DATA on unexpected HTTP/2 stream \(frame.streamIdentifier)."
                )
            }
            streamBuffers[frame.streamIdentifier, default: Data()].append(
                frame.payload
            )
            recordEndOfStream(frame)

        case .headers:
            recordEndOfStream(frame)

        case .settings:
            if frame.flags & Self.acknowledgementFlag == 0 {
                try stateLock.withLock {
                    try flowControl.apply(settings: frame.payload)
                }
                try await sendFrame(
                    type: .settings,
                    flags: Self.acknowledgementFlag
                )
            }

        case .ping:
            if frame.flags & Self.acknowledgementFlag == 0 {
                try await sendFrame(
                    type: .ping,
                    flags: Self.acknowledgementFlag,
                    payload: frame.payload
                )
            }

        case .streamReset:
            guard frame.payload.count == MemoryLayout<UInt32>.size else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC HTTP/2 RST_STREAM payload must contain a 32-bit error code."
                )
            }
            let errorCode: UInt32 = try frame.payload.bigEndianInteger(
                at: 0
            )
            // A file-transfer stream belongs to one upload, so its reset is
            // reported to that upload rather than to unrelated receives.
            let isFileTransferStream = stateLock.withLock {
                flowControl.reset(
                    frame.streamIdentifier,
                    errorCode: errorCode
                )
            }
            if !isFileTransferStream {
                throw RorkDeviceError.remoteXPCStreamReset(
                    streamIdentifier: frame.streamIdentifier,
                    errorCode: errorCode
                )
            }

        case .goAway:
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC closed the HTTP/2 connection."
            )

        case .windowUpdate:
            guard frame.payload.count == MemoryLayout<UInt32>.size else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC HTTP/2 WINDOW_UPDATE payload must contain a 32-bit increment."
                )
            }
            let increment: UInt32 = try frame.payload.bigEndianInteger(
                at: 0
            )
            try stateLock.withLock {
                try flowControl.grant(
                    Int64(increment & 0x7fff_ffff),
                    on: frame.streamIdentifier
                )
            }

        case .none:
            break
        }
    }

    /// Records that the peer ended a file-transfer stream with a DATA or
    /// HEADERS frame carrying END_STREAM.
    private func recordEndOfStream(_ frame: Frame) {
        guard frame.flags & Self.endStreamFlag != 0 else {
            return
        }
        stateLock.withLock {
            if flowControl.isFileTransferStream(frame.streamIdentifier) {
                flowControl.endedByPeer(frame.streamIdentifier)
            }
        }
    }

    /// Closes the underlying service connection.
    func close() {
        connection.close()
    }

    /// Sends the HTTP/2 preface, flow-control settings, and channel setup.
    private func startSession() async throws {
        try await connection.send(Self.clientPreface)

        var settings = Data()
        settings.appendBigEndian(UInt16(0x03))
        settings.appendBigEndian(UInt32(100))
        settings.appendBigEndian(UInt16(0x04))
        settings.appendBigEndian(UInt32(1_048_576))
        try await sendFrame(type: .settings, payload: settings)

        var windowUpdate = Data()
        windowUpdate.appendBigEndian(UInt32(983_041))
        try await sendFrame(type: .windowUpdate, payload: windowUpdate)

        try await open(stream: .control)
        try await send(
            .dictionary([:]),
            flags: Self.alwaysSetFlag,
            messageIdentifier: 0,
            on: .control
        )
        try await receiveHandshakeReply(on: .control)

        try await open(stream: .reply)
        try await send(
            nil,
            flags: Self.initializeReplyStreamFlag | Self.alwaysSetFlag,
            messageIdentifier: 0,
            on: .reply
        )
        try await receiveHandshakeReply(on: .reply)

        try await send(
            nil,
            flags: 0x00000200 | Self.alwaysSetFlag,
            messageIdentifier: 0,
            on: .control
        )
        try await receiveHandshakeReply(on: .control)
    }

    /// Consumes one channel-initialization acknowledgement from a fixed stream.
    ///
    /// Handshake requests use identifier zero, while application requests begin
    /// at one. Checking the echoed identifier prevents a service message from
    /// being silently discarded if the peer omits or reorders an
    /// acknowledgement.
    private func receiveHandshakeReply(on stream: Stream) async throws {
        let message = try await receive(on: stream)
        guard message.messageIdentifier == 0 else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC channel handshake returned message identifier \(message.messageIdentifier) instead of zero."
            )
        }
    }

    /// Opens one fixed RemoteXPC stream with an empty HEADERS block.
    private func open(stream: Stream) async throws {
        try await sendFrame(
            type: .headers,
            flags: Self.endHeadersFlag,
            streamIdentifier: stream.identifier
        )
    }

    /// Encodes and sends one RemoteXPC wrapper on a selected stream.
    private func send(
        _ value: RemoteXPCValue?,
        flags: UInt32,
        messageIdentifier: UInt64,
        on stream: Stream
    ) async throws {
        try await sendFrame(
            type: .data,
            streamIdentifier: stream.identifier,
            payload: RemoteXPCMessageCodec.encode(
                value: value,
                flags: flags,
                messageIdentifier: messageIdentifier
            )
        )
    }

    /// Whether a complete message waits on a stream, leaving it buffered.
    private func hasBufferedMessage(on streamIdentifier: UInt32) throws -> Bool {
        guard let buffer = streamBuffers[streamIdentifier] else {
            return false
        }
        return try RemoteXPCMessageCodec.decodeFirstMessage(from: buffer) != nil
    }

    /// Decodes one message already accumulated for a stream, if complete.
    private func decodeBufferedMessage(
        on streamIdentifier: UInt32
    ) throws -> RemoteXPCMessage? {
        guard let buffer = streamBuffers[streamIdentifier],
              let decoded = try RemoteXPCMessageCodec.decodeFirstMessage(
                  from: buffer
              ) else {
            return nil
        }
        streamBuffers[streamIdentifier] = Data(
            buffer.dropFirst(decoded.consumedByteCount)
        )
        return decoded.message
    }

    /// Writes one HTTP/2 frame after validating its 24-bit payload length.
    ///
    /// DATA frames count against the peer's connection window and the window
    /// of their stream. Uploads reserve their share before sending and pass
    /// `isFlowControlled: false` so it is not charged twice.
    private func sendFrame(
        type: FrameType,
        flags: UInt8 = 0,
        streamIdentifier: UInt32 = 0,
        payload: Data = Data(),
        isFlowControlled: Bool = true
    ) async throws {
        guard payload.count <= 0x00ff_ffff else {
            throw RorkDeviceError.invalidInput(
                "HTTP/2 frame payload exceeds 16,777,215 bytes."
            )
        }
        if type == .data, isFlowControlled {
            stateLock.withLock {
                flowControl.charge(payload.count, on: streamIdentifier)
            }
        }

        var frame = Data([
            UInt8((payload.count >> 16) & 0xff),
            UInt8((payload.count >> 8) & 0xff),
            UInt8(payload.count & 0xff),
            type.rawValue,
            flags,
        ])
        frame.appendBigEndian(streamIdentifier & 0x7fff_ffff)
        frame.append(payload)
        let encodedFrame = frame
        try await writeCoordinator.withExclusiveAccess { [self] in
            try await connection.send(encodedFrame)
        }
    }

    /// Reads one HTTP/2 frame and removes DATA padding before returning it.
    private func receiveFrame() async throws -> Frame {
        let header = try await connection.receive(exactly: 9)
        let payloadLength =
            (Int(header[0]) << 16)
            | (Int(header[1]) << 8)
            | Int(header[2])
        let type = header[3]
        let flags = header[4]
        let rawStreamIdentifier: UInt32 = try header.bigEndianInteger(at: 5)
        let streamIdentifier = rawStreamIdentifier & 0x7fff_ffff
        let payload = try await connection.receive(exactly: payloadLength)

        if type == FrameType.data.rawValue, flags & 0x08 != 0 {
            guard let paddingLength = payload.first,
                  Int(paddingLength) < payload.count else {
                throw RorkDeviceError.protocolViolation(
                    "HTTP/2 DATA frame has invalid padding."
                )
            }
            return Frame(
                type: type,
                flags: flags,
                streamIdentifier: streamIdentifier,
                payload: Data(
                    payload.dropFirst().dropLast(Int(paddingLength))
                )
            )
        }

        return Frame(
            type: type,
            flags: flags,
            streamIdentifier: streamIdentifier,
            payload: payload
        )
    }

    /// Reserves the single receive path that owns frame reads and stream buffers.
    private func beginReceiving() throws {
        try stateLock.withLock {
            guard !isReceiving else {
                throw RorkDeviceError.protocolViolation(
                    "Concurrent RemoteXPC receive operations are not supported."
                )
            }
            isReceiving = true
        }
    }

    /// Releases receive ownership after a message or error leaves `receive`.
    private func endReceiving() {
        stateLock.withLock {
            isReceiving = false
        }
    }
}

/// Coordinates exclusive access to one RemoteXPC transport write path.
///
/// A `DeviceConnection` guarantees complete-buffer writes but does not require
/// implementations to coordinate concurrent callers. This actor owns only the
/// write-slot state, leaving the non-Sendable connection in
/// `RemoteXPCConnection` while ensuring each complete HTTP/2 frame finishes
/// before another write begins.
private actor RemoteXPCWriteCoordinator {
    /// Whether a caller currently owns the write slot.
    private var isWriteInProgress = false

    /// Callers waiting to acquire the write slot in arrival order.
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Executes an asynchronous operation while owning the transport write slot.
    ///
    /// The slot remains reserved across suspension points so another frame
    /// cannot begin writing to the same byte stream. It is released when the
    /// operation returns or throws, including cancellation errors.
    func withExclusiveAccess<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire()
        defer { release() }
        return try await operation()
    }

    /// Suspends until this caller exclusively owns the transport write slot.
    private func acquire() async {
        guard isWriteInProgress else {
            isWriteInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    /// Transfers ownership to the next waiter or marks the slot as available.
    private func release() {
        guard !writeWaiters.isEmpty else {
            isWriteInProgress = false
            return
        }
        writeWaiters.removeFirst().resume()
    }
}
