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
            serviceConnectionTimeout: .seconds(3),
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

/// Loopback listener that records one accepted transport connection.
private final class OneShotTCPServer: @unchecked Sendable {
    /// Underlying listener and event-loop owner.
    private let server: NIOTestServer

    /// Cross-thread acceptance signal shared with the channel handler.
    private let recorder: ConnectionAcceptanceRecorder

    /// Whether an inbound connection has become active.
    var acceptedConnection: Bool {
        recorder.acceptedConnection
    }

    /// Ephemeral port assigned to the loopback listener.
    var port: UInt16 {
        server.port
    }

    /// Starts a listener that closes each connection after recording it.
    init() throws {
        let recorder = ConnectionAcceptanceRecorder()
        self.recorder = recorder
        server = try NIOTestServer { channel in
            channel.pipeline.addHandler(
                ConnectionAcceptanceHandler(recorder: recorder)
            )
        }
    }

    /// Tears down the underlying listener and event loop.
    func stop() {
        server.stop()
    }

    /// Waits for acceptance or throws after the fixture deadline.
    func waitUntilAccepted() async throws {
        try await recorder.waitUntilAccepted()
    }
}

/// Thread-safe acceptance flag shared by a test and its event-loop handler.
private final class ConnectionAcceptanceRecorder:
    @unchecked Sendable
{
    /// Serializes reads and writes of the acceptance flag.
    private let lock = NSLock()

    /// Whether a client connection has become active.
    private var accepted = false

    /// Snapshot of the acceptance flag.
    var acceptedConnection: Bool {
        lock.withLock { accepted }
    }

    /// Records that the listener accepted a connection.
    func recordConnection() {
        lock.withLock {
            accepted = true
        }
    }

    /// Polls until acceptance or a two-second deadline.
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

/// Pipeline handler that turns channel activation into a one-shot test signal.
private final class ConnectionAcceptanceHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    /// Inbound bytes are ignored because connection activation is the signal.
    typealias InboundIn = ByteBuffer

    /// Recorder updated when the accepted channel becomes active.
    private let recorder: ConnectionAcceptanceRecorder

    /// Stores the recorder that receives activation.
    init(recorder: ConnectionAcceptanceRecorder) {
        self.recorder = recorder
    }

    /// Records activation and closes the one-shot connection.
    func channelActive(context: ChannelHandlerContext) {
        recorder.recordConnection()
        context.close(promise: nil)
    }

    /// Closes the accepted channel after a pipeline failure.
    func errorCaught(
        context: ChannelHandlerContext,
        error _: Error
    ) {
        context.close(promise: nil)
    }
}
