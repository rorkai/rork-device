import Foundation
@testable import RorkDevice
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Integration tests for short reads on concrete socket-backed transports.
final class PartialReceiveConnectionTests: XCTestCase {
    /// Verifies TCP short reads return available bytes without waiting for the caller's full capacity.
    func testTCPConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    /// Verifies Unix-domain socket short reads return available bytes without waiting for the caller's full capacity.
    func testUnixConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let server = try UnixDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await UnixDomainSocketConnection.connect(toSocketAt: server.path)
        defer { connection.close() }

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    /// Verifies explicit close prevents later reads from draining stale buffered data.
    func testClosedConnectionDoesNotReturnBufferedBytes() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        try await Task.sleep(for: .milliseconds(50))
        connection.close()

        await XCTAssertThrowsErrorAsync({ _ = try await connection.receive(upTo: 1024) }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("closed"))
        }
    }

    /// Verifies explicit close prevents later writes from entering the NIO channel.
    func testClosedConnectionRejectsLaterSend() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        connection.close()

        await XCTAssertThrowsErrorAsync({ try await connection.send(Data([1])) }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("closed"))
        }
    }

    /// Verifies exact reads also reject new work after explicit close.
    func testClosedConnectionRejectsLaterExactReceive() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        connection.close()

        await XCTAssertThrowsErrorAsync({ _ = try await connection.receive(exactly: 1) }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("closed"))
        }
    }

    /// Verifies explicit close fails a read that is already waiting for bytes.
    func testClosedConnectionRejectsPendingExactReceive() async throws {
        let server = try TCPScriptedServer(chunks: [], closeDelayMicros: 200_000)
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        let pendingRead = Task {
            try await connection.receive(exactly: 1)
        }
        try await Task.sleep(for: .milliseconds(20))
        connection.close()

        await XCTAssertThrowsErrorAsync({ _ = try await pendingRead.value }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("closed"))
        }
    }

    /// Verifies exact reads accumulate bytes delivered across multiple chunks.
    func testExactReceiveAccumulatesBytesDeliveredAcrossChunks() async throws {
        let server = try TCPScriptedServer(
            chunks: [Data("aaa".utf8), Data("bbbb".utf8), Data("cc".utf8)],
            interChunkDelayMicros: 5000
        )
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        let data = try await connection.receive(exactly: 9)

        XCTAssertEqual(data, Data("aaabbbbcc".utf8))
    }

    /// Verifies exact reads fail when the peer closes before they can fill.
    func testExactReceiveThrowsWhenPeerClosesBeforeComplete() async throws {
        let server = try TCPScriptedServer(chunks: [Data("ab".utf8)])
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        await XCTAssertThrowsErrorAsync({ _ = try await connection.receive(exactly: 4) }) { error in
            guard case let RorkDeviceError.transport(message) = error else {
                XCTFail("Expected transport error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("closed"))
        }
    }

    /// Verifies a send completes while a receive is still waiting for bytes.
    func testSendCompletesWhileReceiveIsPending() async throws {
        let server = try TCPScriptedServer(prefixReadLength: 3, chunks: [Data("xyz".utf8)])
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        async let received: Data = connection.receive(exactly: 3)
        try await Task.sleep(for: .milliseconds(20))
        try await connection.send(Data("abc".utf8))
        let response = try await received

        XCTAssertEqual(response, Data("xyz".utf8))
        XCTAssertEqual(server.receivedBytes, Data("abc".utf8))
    }
}

/// One-shot TCP server that accepts a single client and sends fixed bytes.
private final class TCPDataServer {
    /// Bound TCP port in host byte order.
    let port: UInt16

    /// Listening socket owned by the test server.
    private let fileDescriptor: Int32

    /// Payload sent to the first accepted client.
    private let data: Data

    /// Protects idempotent shutdown state.
    private let lock = NSLock()

    /// Tracks whether the listening socket has already been closed.
    private var stopped = false

    /// Starts a loopback TCP server that sends `string` to the first client.
    init(data string: String) throws {
        data = Data(string.utf8)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport(lastTestErrnoMessage("socket"))
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
            throw RorkDeviceError.transport(lastTestErrnoMessage("bind"))
        }
        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport(lastTestErrnoMessage("listen"))
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
            throw RorkDeviceError.transport(lastTestErrnoMessage("getsockname"))
        }

        fileDescriptor = socketFD
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptAndSend()
        }
    }

    deinit {
        stop()
    }

    /// Stops the listening socket. Calling this more than once is safe.
    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            close(fileDescriptor)
        }
    }

    /// Accepts one client connection and writes the configured payload.
    private func acceptAndSend() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        defer { close(clientFD) }
        sendAll(data, to: clientFD)
    }
}

/// One-shot Unix-domain server that accepts a single client and sends fixed bytes.
private final class UnixDataServer {
    /// Filesystem path for the temporary Unix-domain socket.
    let path: String

    /// Listening socket owned by the test server.
    private let fileDescriptor: Int32

    /// Payload sent to the first accepted client.
    private let data: Data

    /// Protects idempotent shutdown state.
    private let lock = NSLock()

    /// Tracks whether the socket and filesystem path have already been removed.
    private var stopped = false

    /// Starts a temporary Unix-domain socket server that sends `string` to the first client.
    init(data string: String) throws {
        data = Data(string.utf8)
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rork-device-\(UUID().uuidString).sock")
            .path

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport(lastTestErrnoMessage("socket"))
        }

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < maxPathLength else {
                throw RorkDeviceError.invalidInput("Unix socket path is too long: \(path)")
            }

            _ = path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                    tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                        strncpy(destination, source, maxPathLength - 1)
                    }
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw RorkDeviceError.transport(lastTestErrnoMessage("bind"))
            }
            guard listen(socketFD, 1) == 0 else {
                throw RorkDeviceError.transport(lastTestErrnoMessage("listen"))
            }

            fileDescriptor = socketFD

            Thread.detachNewThread { [weak self] in
                self?.acceptAndSend()
            }
        } catch {
            close(socketFD)
            unlink(path)
            throw error
        }
    }

    deinit {
        stop()
    }

    /// Stops the listening socket and removes its temporary path.
    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            close(fileDescriptor)
            unlink(path)
        }
    }

    /// Accepts one client connection and writes the configured payload.
    private func acceptAndSend() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        defer { close(clientFD) }
        sendAll(data, to: clientFD)
    }
}

/// Sends an entire buffer to a blocking test socket.
private func sendAll(_ data: Data, to fileDescriptor: Int32) {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }

        var sent = 0
        while sent < data.count {
            let result = send(fileDescriptor, baseAddress.advanced(by: sent), data.count - sent, 0)
            guard result > 0 else {
                return
            }
            sent += result
        }
    }
}

/// Formats `errno` for test helper failures.
private func lastTestErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}

/// Scripted TCP server that optionally records a request, then streams chunks.
private final class TCPScriptedServer {
    /// Bound TCP port in host byte order.
    let port: UInt16

    /// Listening socket owned by the test server.
    private let fileDescriptor: Int32

    /// Number of request bytes to read and record before sending chunks.
    private let prefixReadLength: Int

    /// Ordered payload chunks streamed to the accepted client.
    private let chunks: [Data]

    /// Delay inserted before every chunk after the first.
    private let interChunkDelayMicros: useconds_t

    /// Delay inserted before closing the accepted client socket.
    private let closeDelayMicros: useconds_t

    /// Protects recorded request bytes and idempotent shutdown state.
    private let lock = NSLock()

    /// Request bytes read from the client before streaming the response.
    private var _received = Data()

    /// Tracks whether the listening socket has already been closed.
    private var stopped = false

    /// Bytes the server read from the client before streaming its chunks.
    var receivedBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    /// Starts a loopback TCP server that records a request and streams chunks.
    init(
        prefixReadLength: Int = 0,
        chunks: [Data],
        interChunkDelayMicros: useconds_t = 0,
        closeDelayMicros: useconds_t = 0
    ) throws {
        self.prefixReadLength = prefixReadLength
        self.chunks = chunks
        self.interChunkDelayMicros = interChunkDelayMicros
        self.closeDelayMicros = closeDelayMicros

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport(lastTestErrnoMessage("socket"))
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
            throw RorkDeviceError.transport(lastTestErrnoMessage("bind"))
        }
        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport(lastTestErrnoMessage("listen"))
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
            throw RorkDeviceError.transport(lastTestErrnoMessage("getsockname"))
        }

        fileDescriptor = socketFD
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptAndRun()
        }
    }

    deinit {
        stop()
    }

    /// Stops the listening socket. Calling this more than once is safe.
    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            close(fileDescriptor)
        }
    }

    /// Accepts one client, records the optional request, and streams chunks.
    private func acceptAndRun() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        defer { close(clientFD) }

        if prefixReadLength > 0 {
            let request = recvExactly(prefixReadLength, from: clientFD)
            lock.lock()
            _received = request
            lock.unlock()
        }

        for (index, chunk) in chunks.enumerated() {
            if index > 0, interChunkDelayMicros > 0 {
                usleep(interChunkDelayMicros)
            }
            sendAll(chunk, to: clientFD)
        }
        if closeDelayMicros > 0 {
            usleep(closeDelayMicros)
        }
    }
}

/// Reads exactly `count` bytes from a blocking test socket, or fewer on EOF.
private func recvExactly(_ count: Int, from fileDescriptor: Int32) -> Data {
    var received = Data()
    var scratch = [UInt8](repeating: 0, count: count)
    while received.count < count {
        let remaining = count - received.count
        let read = scratch.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return recv(fileDescriptor, baseAddress, remaining, 0)
        }
        guard read > 0 else {
            break
        }
        received.append(contentsOf: scratch[0 ..< read])
    }
    return received
}
