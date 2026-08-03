import Foundation
import NIOCore
import XCTest
@testable import RorkDevice

final class DirectLockdownTransportTests: XCTestCase {
    func testConnectsToByteSwappedServicePortWhenDirectPortIsRefused() async throws {
        let server = try OneShotTCPServer()
        defer { server.stop() }

        let requestedPort = server.port.byteSwapped
        let transport = DirectLockdownTransport(
            host: "127.0.0.1",
            serviceConnectionTimeout: .seconds(1),
            serviceConnectionRetryDelay: .zero
        )

        let connection = try await transport.connect(to: requestedPort)
        connection.close()
        try await server.waitUntilAccepted()

        XCTAssertTrue(server.acceptedConnection)
    }

    func testConnectionFailureIncludesAttemptedServicePorts() async throws {
        let transport = DirectLockdownTransport(
            host: "127.0.0.1",
            serviceConnectionTimeout: .milliseconds(200),
            serviceConnectionRetryDelay: .zero
        )
        let requestedPort = UInt16(9)

        await XCTAssertThrowsErrorAsync({ _ = try await transport.connect(to: requestedPort) }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("service port 9"))
            XCTAssertTrue(message.contains("reported=9"))
            XCTAssertTrue(message.contains("byte-swapped=2304"))
        }
    }
}

private final class OneShotTCPServer: @unchecked Sendable {
    private let server: NIOTestServer
    private let recorder: ConnectionAcceptanceRecorder

    var acceptedConnection: Bool {
        recorder.acceptedConnection
    }

    var port: UInt16 {
        server.port
    }

    init() throws {
        let recorder = ConnectionAcceptanceRecorder()
        self.recorder = recorder
        server = try NIOTestServer { channel in
            channel.pipeline.addHandler(
                ConnectionAcceptanceHandler(recorder: recorder)
            )
        }
    }

    func stop() {
        server.stop()
    }

    func waitUntilAccepted() async throws {
        try await recorder.waitUntilAccepted()
    }
}

private final class ConnectionAcceptanceRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var accepted = false

    var acceptedConnection: Bool {
        lock.withLock { accepted }
    }

    func recordConnection() {
        lock.withLock {
            accepted = true
        }
    }

    func waitUntilAccepted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !lock.withLock({ accepted }) {
            if clock.now >= deadline {
                throw RorkDeviceError.transport(
                    "Timed out waiting for the test server to accept a connection."
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ConnectionAcceptanceHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let recorder: ConnectionAcceptanceRecorder

    init(recorder: ConnectionAcceptanceRecorder) {
        self.recorder = recorder
    }

    func channelActive(context: ChannelHandlerContext) {
        recorder.recordConnection()
        context.close(promise: nil)
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error _: Error
    ) {
        context.close(promise: nil)
    }
}
