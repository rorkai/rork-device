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
        await server.waitUntilAccepted()

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

    func waitUntilAccepted() async {
        await recorder.waitUntilAccepted()
    }
}

private final class ConnectionAcceptanceRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var accepted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var acceptedConnection: Bool {
        lock.withLock { accepted }
    }

    func recordConnection() {
        let waiters = lock.withLock {
            accepted = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilAccepted() async {
        if lock.withLock({ accepted }) {
            return
        }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if accepted {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
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
