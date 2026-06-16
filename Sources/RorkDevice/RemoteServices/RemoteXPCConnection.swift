import Foundation

/// Bidirectional RemoteXPC session carried over the device's HTTP/2 transport.
///
/// Apple services exposed through Remote Service Discovery use two fixed HTTP/2
/// streams. The host writes requests on the control stream, while services may
/// return feature responses on the device-initiated reply stream. Session
/// startup exchanges acknowledgements on both streams before either becomes
/// available to service-specific code.
final class RemoteXPCConnection {
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
        case resetStream = 0x03

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

    /// Connected byte stream carrying the HTTP/2 session.
    private let connection: DeviceConnection

    /// Incomplete RemoteXPC bytes accumulated independently for each stream.
    private var streamBuffers: [UInt32: Data] = [:]

    /// Identifier assigned to the next application-level message.
    private var nextMessageIdentifier: UInt64 = 1

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
        let flags = Self.alwaysSetFlag
            | (value == nil ? 0 : Self.dataFlag)
            | additionalFlags
        try await send(
            value,
            flags: flags,
            messageIdentifier: nextMessageIdentifier,
            on: .control
        )
        nextMessageIdentifier += 1
    }

    /// Receives the next complete message from one logical stream.
    ///
    /// DATA frames for the other stream remain buffered, allowing callers to
    /// consume asynchronous replies later without losing bytes while waiting on
    /// the control stream.
    func receive(
        on stream: Stream = .control
    ) async throws -> RemoteXPCMessage {
        while true {
            if let decoded = try decodeBufferedMessage(on: stream.identifier) {
                return decoded
            }

            let frame = try await receiveFrame()
            switch FrameType(rawValue: frame.type) {
            case .data:
                streamBuffers[frame.streamIdentifier, default: Data()].append(
                    frame.payload
                )

            case .settings:
                if frame.flags & Self.acknowledgementFlag == 0 {
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

            case .resetStream:
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC reset HTTP/2 stream \(frame.streamIdentifier)."
                )

            case .goAway:
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC closed the HTTP/2 connection."
                )

            case .headers, .windowUpdate, .none:
                continue
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
    private func sendFrame(
        type: FrameType,
        flags: UInt8 = 0,
        streamIdentifier: UInt32 = 0,
        payload: Data = Data()
    ) async throws {
        guard payload.count <= 0x00ff_ffff else {
            throw RorkDeviceError.invalidInput(
                "HTTP/2 frame payload exceeds 16,777,215 bytes."
            )
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
        try await connection.send(frame)
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
}
