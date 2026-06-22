import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import XCTest

@testable import RorkDevice

/// Tests for the platform default secure-session selection.
final class SecureSessionUpgraderTests: XCTestCase {
    /// Verifies that the default upgrader validates pairing material before use.
    func testDefaultUpgraderValidatesPairingMaterial() async throws {
        let pairingRecord = try PairingRecord.parse(
            PropertyListSerialization.data(
                fromPropertyList: [
                    "UDID": "device-1",
                    "HostID": "host-1",
                    "SystemBUID": "system-1",
                ],
                format: .xml,
                options: 0
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await DefaultSecureSessionUpgrader().upgrade(
                FakeConnection(),
                pairingRecord: pairingRecord
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError, .invalidPairingRecord("Missing DeviceCertificate."))
        }
    }

    /// Verifies that the NIO backend adds TLS to an established device stream.
    func testNIOSecureSessionUpgraderExchangesDataOverExistingConnection() async throws {
        let server = try await SecureSessionTestServer.start()
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(
            to: "127.0.0.1",
            port: server.port
        )
        defer { connection.close() }
        try await connection.send(SecureSessionTestServer.upgradeRequest)
        let upgradeResponse = try await connection.receive(
            exactly: SecureSessionTestServer.upgradeResponse.count
        )
        XCTAssertEqual(
            upgradeResponse,
            SecureSessionTestServer.upgradeResponse
        )

        let secureConnection = try await NIOSecureSessionUpgrader().upgrade(
            connection,
            pairingRecord: try makeSecureSessionPairingRecord()
        )

        let payload = Data("Lockdown over TLS".utf8)
        try await secureConnection.send(payload)
        let received = try await secureConnection.receive(
            exactly: payload.count
        )

        XCTAssertEqual(received, payload)
    }

    /// Verifies that TLS can wrap an arbitrary streaming device transport.
    func testNIOSecureSessionUpgraderExchangesDataOverStreamingConnection() async throws {
        let server = try await SecureSessionTestServer.start()
        defer { server.stop() }

        let socketConnection = try await TCPDeviceConnection.connect(
            to: "127.0.0.1",
            port: server.port
        )
        let connection = TestStreamingConnection(
            wrapping: socketConnection
        )
        defer { connection.close() }

        try await connection.send(SecureSessionTestServer.upgradeRequest)
        let upgradeResponse = try await connection.receive(
            exactly: SecureSessionTestServer.upgradeResponse.count
        )
        XCTAssertEqual(
            upgradeResponse,
            SecureSessionTestServer.upgradeResponse
        )

        let secureConnection = try await NIOSecureSessionUpgrader().upgrade(
            connection,
            pairingRecord: try makeSecureSessionPairingRecord()
        )

        let payload = Data("Transport-neutral TLS".utf8)
        try await secureConnection.send(payload)
        let received = try await secureConnection.receive(
            exactly: payload.count
        )

        XCTAssertEqual(received, payload)
    }

    /// Verifies that the WASM-style embedded client emits its initial TLS flight.
    func testEmbeddedTLSChannelActivationEmitsClientHello() async throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        let context = try NIOSSLContext(configuration: configuration)
        let tlsHandler = try NIOSSLClientHandler(
            context: context,
            serverHostname: nil
        )
        let channel = EmbeddedChannel(handler: tlsHandler)
        let address = try SocketAddress(
            ipAddress: "127.0.0.1",
            port: 0
        )

        try await activateEmbeddedTLSChannel(
            channel,
            connectingTo: address
        )

        guard
            case .byteBuffer(let clientHello)? =
                try channel.readOutbound(as: IOData.self)
        else {
            return XCTFail("Embedded TLS activation did not emit a ClientHello.")
        }
        XCTAssertGreaterThan(clientHello.readableBytes, 0)
    }

    /// Verifies that the device certificate remains pinned to the pairing record.
    func testNIOSecureSessionUpgraderRejectsUnexpectedDeviceCertificate() async throws {
        let server = try await SecureSessionTestServer.start()
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(
            to: "127.0.0.1",
            port: server.port
        )
        defer { connection.close() }
        try await connection.send(SecureSessionTestServer.upgradeRequest)
        let upgradeResponse = try await connection.receive(
            exactly: SecureSessionTestServer.upgradeResponse.count
        )
        XCTAssertEqual(
            upgradeResponse,
            SecureSessionTestServer.upgradeResponse
        )

        let pairingRecord = try makeSecureSessionPairingRecord(
            deviceCertificate: try secureSessionFixture(
                named: "host-certificate"
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await NIOSecureSessionUpgrader().upgrade(
                connection,
                pairingRecord: pairingRecord
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .secureSession(
                    "Device server certificate did not match the pairing record."
                )
            )
        }
    }

    /// Verifies that callers receive an explicit error for non-NIO transports.
    func testNIOSecureSessionUpgraderRejectsUnsupportedConnection() async throws {
        await XCTAssertThrowsErrorAsync({
            _ = try await NIOSecureSessionUpgrader().upgrade(
                FakeConnection(),
                pairingRecord: try makeSecureSessionPairingRecord()
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .secureSessionUnsupported
            )
        }
    }
}

/// Hides the socket-specific TLS capability while preserving streaming reads.
private final class TestStreamingConnection:
    StreamingDeviceConnection,
    @unchecked Sendable
{
    /// Wrapped socket used only as an opaque byte stream.
    private let connection: TCPDeviceConnection

    /// Creates an opaque streaming wrapper around a concrete socket.
    init(wrapping connection: TCPDeviceConnection) {
        self.connection = connection
    }

    /// Forwards a complete plaintext or ciphertext write.
    func send(_ data: Data) async throws {
        try await connection.send(data)
    }

    /// Forwards an exact read.
    func receive(exactly byteCount: Int) async throws -> Data {
        try await connection.receive(exactly: byteCount)
    }

    /// Forwards a short read without revealing the concrete socket type.
    func receive(upTo byteCount: Int) async throws -> Data {
        try await connection.receive(upTo: byteCount)
    }

    /// Closes the wrapped socket.
    func close() {
        connection.close()
    }
}

/// Local TLS server that requires the host certificate from the pairing record.
private final class SecureSessionTestServer {
    /// Plaintext request that asks the fixture to begin TLS.
    static let upgradeRequest = Data("START-TLS".utf8)

    /// Plaintext acknowledgement sent before the TLS handler is inserted.
    static let upgradeResponse = Data("READY".utf8)

    /// Event-loop group owned by this server instance.
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    /// Listening channel that owns accepted TLS connections.
    private let channel: Channel

    /// Ephemeral loopback port selected by the operating system.
    let port: UInt16

    /// Retains an initialized listener and its event-loop group.
    private init(
        eventLoopGroup: MultiThreadedEventLoopGroup,
        channel: Channel,
        port: UInt16
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.channel = channel
        self.port = port
    }

    /// Starts a mutual-TLS echo server using the test pairing credentials.
    static func start() async throws -> SecureSessionTestServer {
        let deviceCertificate = try NIOSSLCertificate(
            bytes: Array(
                try secureSessionFixture(named: "device-certificate")
            ),
            format: .pem
        )
        let devicePrivateKey = try NIOSSLPrivateKey(
            bytes: Array(
                try secureSessionFixture(named: "device-private-key")
            ),
            format: .pem
        )
        let rootCertificate = try NIOSSLCertificate(
            bytes: Array(
                try secureSessionFixture(named: "root-certificate")
            ),
            format: .pem
        )
        let configuration = TLSConfiguration.makeServerConfigurationWithMTLS(
            certificateChain: [
                .certificate(deviceCertificate),
                .certificate(rootCertificate),
            ],
            privateKey: .privateKey(devicePrivateKey),
            trustRoots: .certificates([rootCertificate])
        )
        let context = try NIOSSLContext(configuration: configuration)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let channel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            SecureSessionStartTLSHandler(tlsContext: context)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port,
                let port = UInt16(exactly: port)
            else {
                channel.close(promise: nil)
                try await eventLoopGroup.shutdownGracefully()
                throw RorkDeviceError.transport(
                    "TLS test server did not receive a valid local port."
                )
            }
            return SecureSessionTestServer(
                eventLoopGroup: eventLoopGroup,
                channel: channel,
                port: port
            )
        } catch {
            try await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    /// Stops accepting connections and releases the server event loop.
    func stop() {
        channel.close(promise: nil)
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

/// Starts TLS after a plaintext marker, then echoes decrypted application data.
private final class SecureSessionStartTLSHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// TLS context used when the plaintext upgrade request arrives.
    private let tlsContext: NIOSSLContext

    /// Whether subsequent channel reads contain decrypted application bytes.
    private var isSecure = false

    /// Accumulates a possibly fragmented plaintext upgrade request.
    private var upgradeBuffer = ByteBufferAllocator().buffer(capacity: 0)

    /// Creates a handler that upgrades one accepted test connection.
    init(tlsContext: NIOSSLContext) {
        self.tlsContext = tlsContext
    }

    /// Consumes the plaintext marker or echoes post-handshake data.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if isSecure {
            context.write(data, promise: nil)
            return
        }

        upgradeBuffer.writeImmutableBuffer(unwrapInboundIn(data))
        let requestLength = SecureSessionTestServer.upgradeRequest.count
        guard upgradeBuffer.readableBytes >= requestLength else {
            return
        }
        guard
            upgradeBuffer.readData(length: requestLength)
                == SecureSessionTestServer.upgradeRequest,
            upgradeBuffer.readableBytes == 0
        else {
            context.fireErrorCaught(
                RorkDeviceError.protocolViolation(
                    "TLS test server received an invalid upgrade request."
                )
            )
            context.close(promise: nil)
            return
        }

        var response = context.channel.allocator.buffer(
            capacity: SecureSessionTestServer.upgradeResponse.count
        )
        response.writeBytes(SecureSessionTestServer.upgradeResponse)
        let loopBoundContext = context.loopBound
        let loopBoundSelf = NIOLoopBound(
            self,
            eventLoop: context.eventLoop
        )
        context.writeAndFlush(wrapOutboundOut(response)).whenComplete { result in
            let context = loopBoundContext.value
            let handler = loopBoundSelf.value
            switch result {
            case .success:
                do {
                    try context.pipeline.syncOperations.addHandler(
                        NIOSSLServerHandler(context: handler.tlsContext),
                        position: .first
                    )
                    handler.isSecure = true
                } catch {
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                }
            case .failure(let error):
                context.fireErrorCaught(error)
                context.close(promise: nil)
            }
        }
    }

    /// Flushes echoed application data after TLS is active.
    func channelReadComplete(context: ChannelHandlerContext) {
        if isSecure {
            context.flush()
        }
    }
}

/// Builds a pairing record containing the generated mutual-TLS credentials.
private func makeSecureSessionPairingRecord(
    deviceCertificate: Data? = nil
) throws -> PairingRecord {
    let resolvedDeviceCertificate: Data
    if let suppliedDeviceCertificate = deviceCertificate {
        resolvedDeviceCertificate = suppliedDeviceCertificate
    } else {
        resolvedDeviceCertificate = try secureSessionFixture(
            named: "device-certificate"
        )
    }

    return try PairingRecord.parse(
        PropertyListSerialization.data(
            fromPropertyList: [
                "UDID": "secure-session-test-device",
                "HostID": "secure-session-test-host",
                "SystemBUID": "secure-session-test-system",
                "DeviceCertificate": resolvedDeviceCertificate,
                "HostCertificate": try secureSessionFixture(
                    named: "host-certificate"
                ),
                "HostPrivateKey": try secureSessionFixture(
                    named: "host-private-key"
                ),
                "RootCertificate": try secureSessionFixture(
                    named: "root-certificate"
                ),
            ],
            format: .binary,
            options: 0
        )
    )
}

/// Loads one generated certificate or private key from test resources.
private func secureSessionFixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(
            forResource: name,
            withExtension: "pem"
        ),
        "Missing TLS test fixture \(name).pem."
    )
    return try Data(contentsOf: url)
}
