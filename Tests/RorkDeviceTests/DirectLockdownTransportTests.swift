import Foundation
import XCTest
@testable import RorkDevice

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Thread-safe one-shot server used by direct Lockdown transport tests.
///
/// The detached accept thread shares the listening descriptor with `stop()`.
/// Its only mutable result and lifecycle state are protected by `lock`.
private final class OneShotTCPServer: @unchecked Sendable {
    let port: UInt16

    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var accepted = false

    var acceptedConnection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    init() throws {
        let socketFD = socket(AF_INET, testStreamSocketType, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport("socket failed: \(String(cString: strerror(errno)))")
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport("bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport("listen failed: \(String(cString: strerror(errno)))")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport("getsockname failed: \(String(cString: strerror(errno)))")
        }
        fd = socketFD
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptOne()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            close(fd)
        }
    }

    private func acceptOne() {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        lock.lock()
        accepted = true
        lock.unlock()
        close(clientFD)
    }
}
