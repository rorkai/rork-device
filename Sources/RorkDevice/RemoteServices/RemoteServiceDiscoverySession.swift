import Foundation

/// Owns a live discovery connection and the service directory it advertised.
final class RemoteServiceDiscoverySession {
    /// Service map whose ports remain valid while this session is retained.
    let directory: RemoteServiceDirectory

    /// Underlying HTTP/2 and RemoteXPC connection kept open for port validity.
    private let connection: DeviceConnection

    /// Protects idempotent closure from explicit calls and `deinit`.
    private let stateLock = NSLock()

    /// Records whether ownership of the connection has already been released.
    private var isClosed = false

    /// Creates a session after the discovery handshake has completed.
    private init(directory: RemoteServiceDirectory, connection: DeviceConnection) {
        self.directory = directory
        self.connection = connection
    }

    /// Completes discovery over an established connection and takes ownership of it.
    static func open(over connection: DeviceConnection) async throws -> RemoteServiceDiscoverySession {
        let protocolConnection = RemoteServiceDiscoveryProtocol(connection: connection)
        do {
            try await protocolConnection.startSession()
            let directory = try await protocolConnection.receiveServiceDirectory()
            return RemoteServiceDiscoverySession(
                directory: directory,
                connection: connection
            )
        } catch {
            connection.close()
            throw error
        }
    }

    /// Closes the owned connection when the session leaves memory.
    deinit {
        close()
    }

    /// Closes the discovery connection exactly once.
    func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()
        connection.close()
    }
}

/// Performs the minimal HTTP/2 and RemoteXPC exchange required for discovery.
private final class RemoteServiceDiscoveryProtocol {
    /// HTTP/2 frame types needed by the Remote Service Discovery handshake.
    private enum FrameType: UInt8 {
        /// Carries RemoteXPC message bytes.
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

    /// Decoded HTTP/2 frame used by the discovery state machine.
    private struct Frame {
        /// Raw frame type so unknown values can be ignored safely.
        let type: UInt8

        /// HTTP/2 frame flags supplied by the peer.
        let flags: UInt8

        /// Stream identifier with the reserved bit removed.
        let streamIdentifier: UInt32

        /// Frame payload after optional DATA padding has been removed.
        let payload: Data
    }

    /// HTTP/2 client connection preface required before the first frame.
    private static let clientPreface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    /// Stream carrying the discovery handshake and service advertisement.
    private static let rootStream: UInt32 = 1

    /// Companion stream required by the RemoteXPC channel setup.
    private static let replyStream: UInt32 = 3

    /// HTTP/2 flag indicating that a HEADERS block is complete.
    private static let endHeadersFlag: UInt8 = 0x04

    /// Shared acknowledgement flag used by SETTINGS and PING.
    private static let acknowledgementFlag: UInt8 = 0x01

    /// Connected byte stream carrying the HTTP/2 session.
    private let connection: DeviceConnection

    /// Incomplete RemoteXPC bytes accumulated independently for each stream.
    private var streamBuffers: [UInt32: Data] = [:]

    /// Creates a discovery protocol driver over an established byte stream.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Sends the HTTP/2 preface, flow-control settings, and RemoteXPC setup messages.
    func startSession() async throws {
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

        try await sendFrame(
            type: .headers,
            flags: Self.endHeadersFlag,
            streamIdentifier: Self.rootStream
        )
        try await sendXPC(
            value: .dictionary([:]),
            flags: 0x00000001,
            streamIdentifier: Self.rootStream
        )
        try await sendXPC(
            value: nil,
            flags: 0x00000201,
            streamIdentifier: Self.rootStream
        )

        try await sendFrame(
            type: .headers,
            flags: Self.endHeadersFlag,
            streamIdentifier: Self.replyStream
        )
        try await sendXPC(
            value: nil,
            flags: 0x00400001,
            streamIdentifier: Self.replyStream
        )
    }

    /// Waits for the RemoteXPC handshake carrying device properties and services.
    func receiveServiceDirectory() async throws -> RemoteServiceDirectory {
        while true {
            let message = try await receiveXPC(on: Self.rootStream)
            guard let root = message.value?.dictionaryValue else {
                continue
            }
            guard root["MessageType"]?.stringValue == "Handshake" else {
                continue
            }
            return try parseDirectory(from: root)
        }
    }

    /// Encodes and sends one RemoteXPC message on an HTTP/2 stream.
    private func sendXPC(
        value: RemoteXPCValue?,
        flags: UInt32,
        streamIdentifier: UInt32
    ) async throws {
        try await sendFrame(
            type: .data,
            streamIdentifier: streamIdentifier,
            payload: RemoteXPCMessageCodec.encode(
                value: value,
                flags: flags,
                messageIdentifier: 0
            )
        )
    }

    /// Receives the next complete RemoteXPC message from a selected stream.
    private func receiveXPC(on streamIdentifier: UInt32) async throws -> RemoteXPCMessage {
        while true {
            if let decoded = try decodeBufferedMessage(on: streamIdentifier) {
                return decoded
            }

            let frame = try await receiveFrame()
            switch FrameType(rawValue: frame.type) {
            case .data:
                streamBuffers[frame.streamIdentifier, default: Data()].append(frame.payload)

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
                    "Remote Service Discovery reset HTTP/2 stream \(frame.streamIdentifier)."
                )

            case .goAway:
                throw RorkDeviceError.protocolViolation(
                    "Remote Service Discovery closed the HTTP/2 connection."
                )

            case .headers, .windowUpdate, .none:
                continue
            }
        }
    }

    /// Decodes one message already accumulated for a stream, if complete.
    private func decodeBufferedMessage(on streamIdentifier: UInt32) throws -> RemoteXPCMessage? {
        guard let buffer = streamBuffers[streamIdentifier],
              let decoded = try RemoteXPCMessageCodec.decodeFirstMessage(from: buffer) else {
            return nil
        }
        streamBuffers[streamIdentifier] = Data(buffer.dropFirst(decoded.consumedByteCount))
        return decoded.message
    }

    /// Writes one HTTP/2 frame after validating the 24-bit payload length.
    private func sendFrame(
        type: FrameType,
        flags: UInt8 = 0,
        streamIdentifier: UInt32 = 0,
        payload: Data = Data()
    ) async throws {
        guard payload.count <= 0x00ff_ffff else {
            throw RorkDeviceError.invalidInput("HTTP/2 frame payload exceeds 16,777,215 bytes.")
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
                payload: Data(payload.dropFirst().dropLast(Int(paddingLength)))
            )
        }

        return Frame(
            type: type,
            flags: flags,
            streamIdentifier: streamIdentifier,
            payload: payload
        )
    }

    /// Validates the discovery handshake and extracts its device-bound service map.
    private func parseDirectory(
        from handshake: [String: RemoteXPCValue]
    ) throws -> RemoteServiceDirectory {
        guard let properties = handshake["Properties"]?.dictionaryValue,
              let deviceIdentifier = properties["UniqueDeviceID"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceIdentifier.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake does not contain a device identifier."
            )
        }
        guard let advertisedServices = handshake["Services"]?.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake does not contain a service directory."
            )
        }

        var services: [String: UInt16] = [:]
        for (name, value) in advertisedServices {
            guard let attributes = value.dictionaryValue,
                  let rawPort = attributes["Port"]?.integerValue else {
                continue
            }
            guard let port = UInt16(exactly: rawPort), port > 0 else {
                throw RorkDeviceError.protocolViolation(
                    "Remote service \(name) has invalid port \(rawPort)."
                )
            }
            services[name] = port
        }

        guard !services.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake contains no service ports."
            )
        }
        return RemoteServiceDirectory(
            deviceIdentifier: deviceIdentifier,
            services: services
        )
    }
}
