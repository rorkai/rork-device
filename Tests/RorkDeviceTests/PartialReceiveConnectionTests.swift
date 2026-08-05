import Foundation
import NIOCore
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
    #if !os(Windows)
    func testUnixConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let server = try UnixDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await UnixDomainSocketConnection.connect(toSocketAt: server.path)
        defer { connection.close() }

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }
    #endif

    /// Verifies explicit close prevents later reads from draining stale buffered data.
    func testClosedConnectionDoesNotReturnBufferedBytes() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        try await Task.sleep(for: .milliseconds(50))
        connection.close()

        await XCTAssertThrowsErrorAsync({ _ = try await connection.receive(upTo: 1024) }) { error in
            assertTransportError(error, equals: "Connection is closed.")
        }
    }

    /// Verifies explicit close prevents later writes from entering the NIO channel.
    func testClosedConnectionRejectsLaterSend() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        connection.close()

        await XCTAssertThrowsErrorAsync({ try await connection.send(Data([1])) }) { error in
            assertTransportError(error, equals: "Connection is closed.")
        }
    }

    /// Verifies exact reads also reject new work after explicit close.
    func testClosedConnectionRejectsLaterExactReceive() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        connection.close()

        await XCTAssertThrowsErrorAsync({ _ = try await connection.receive(exactly: 1) }) { error in
            assertTransportError(error, equals: "Connection is closed.")
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
            assertTransportError(error, equals: "Connection is closed.")
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
            assertTransportError(error, equals: "Connection closed.")
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

/// Loopback server that sends one fixed payload to the first client.
private final class TCPDataServer: @unchecked Sendable {
    /// Underlying listener and event-loop owner.
    private let server: NIOTestServer

    /// Ephemeral port assigned to the listener.
    var port: UInt16 {
        server.port
    }

    /// Starts a server that sends the UTF-8 bytes of `string`.
    init(data string: String) throws {
        let data = Data(string.utf8)
        server = try NIOTestServer { channel in
            channel.pipeline.addHandler(
                FixedDataServerHandler(data: data)
            )
        }
    }

    /// Tears down the underlying listener and event loop.
    func stop() {
        server.stop()
    }
}

/// Pipeline handler that writes a fixed payload and then closes the stream.
private final class FixedDataServerHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    /// Inbound bytes are ignored by this write-only fixture.
    typealias InboundIn = ByteBuffer

    /// Outbound payloads use the channel's byte-buffer representation.
    typealias OutboundOut = ByteBuffer

    /// Payload written when the accepted channel becomes active.
    private let data: Data

    /// Stores the fixed payload for the accepted connection.
    init(data: Data) {
        self.data = data
    }

    /// Flushes the payload and closes after the write completes.
    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    /// Closes the accepted channel after a pipeline failure.
    func errorCaught(
        context: ChannelHandlerContext,
        error _: Error
    ) {
        context.close(promise: nil)
    }
}

#if !os(Windows)
/// One-shot Unix-domain server that accepts a single client and sends fixed bytes.
///
/// The detached accept thread reads immutable socket, path, and payload state.
/// `lock` protects the only mutable lifecycle flag shared with `stop()`.
private final class UnixDataServer: @unchecked Sendable {
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

        let socketFD = socket(AF_UNIX, testStreamSocketType, 0)
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
#endif

/// Asserts that an error is the expected package transport failure.
private func assertTransportError(
    _ error: Error,
    equals expectedMessage: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let RorkDeviceError.transport(message) = error else {
        XCTFail("Expected transport error, got \(error)", file: file, line: line)
        return
    }
    XCTAssertEqual(message, expectedMessage, file: file, line: line)
}

/// Loopback server that runs a timed sequence of reads, writes, and closure.
private final class TCPScriptedServer: @unchecked Sendable {
    /// Underlying listener and event-loop owner.
    private let server: NIOTestServer

    /// Thread-safe recorder for the optional inbound prefix.
    private let recorder: ScriptedServerRecorder

    /// Ephemeral port assigned to the listener.
    var port: UInt16 {
        server.port
    }

    /// Prefix bytes received before scripted transmission began.
    var receivedBytes: Data {
        recorder.receivedBytes
    }

    /// Starts a server with optional prefix capture and timed response chunks.
    init(
        prefixReadLength: Int = 0,
        chunks: [Data],
        interChunkDelayMicros: Int64 = 0,
        closeDelayMicros: Int64 = 0
    ) throws {
        let recorder = ScriptedServerRecorder()
        self.recorder = recorder
        server = try NIOTestServer { channel in
            channel.pipeline.addHandler(
                ScriptedServerHandler(
                    prefixReadLength: prefixReadLength,
                    chunks: chunks,
                    interChunkDelayMicros: interChunkDelayMicros,
                    closeDelayMicros: closeDelayMicros,
                    recorder: recorder
                )
            )
        }
    }

    /// Tears down the underlying listener and event loop.
    func stop() {
        server.stop()
    }
}

/// Thread-safe accumulator for bytes read before a scripted response.
private final class ScriptedServerRecorder: @unchecked Sendable {
    /// Serializes access to the recorded bytes.
    private let lock = NSLock()

    /// Most recently recorded prefix bytes.
    private var received = Data()

    /// Snapshot of the recorded prefix bytes.
    var receivedBytes: Data {
        lock.withLock { received }
    }

    /// Replaces the recorded prefix with one completed read.
    func record(_ data: Data) {
        lock.withLock {
            received = data
        }
    }
}

/// Pipeline handler that drives one configured response script.
private final class ScriptedServerHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    /// Inbound bytes may satisfy the script's prefix read.
    typealias InboundIn = ByteBuffer

    /// Scripted response chunks use the channel's byte-buffer representation.
    typealias OutboundOut = ByteBuffer

    /// Number of inbound bytes required before transmission starts.
    private let prefixReadLength: Int

    /// Response chunks written in order.
    private let chunks: [Data]

    /// Delay inserted between adjacent response chunks.
    private let interChunkDelayMicros: Int64

    /// Delay between the final write and channel closure.
    private let closeDelayMicros: Int64

    /// Recorder that receives the configured inbound prefix.
    private let recorder: ScriptedServerRecorder

    /// Partial inbound bytes waiting to satisfy `prefixReadLength`.
    private var pending = ByteBuffer()

    /// Whether the response script has already been scheduled.
    private var started = false

    /// Captures the timing, payload, and recording contract for one connection.
    init(
        prefixReadLength: Int,
        chunks: [Data],
        interChunkDelayMicros: Int64,
        closeDelayMicros: Int64,
        recorder: ScriptedServerRecorder
    ) {
        self.prefixReadLength = prefixReadLength
        self.chunks = chunks
        self.interChunkDelayMicros = interChunkDelayMicros
        self.closeDelayMicros = closeDelayMicros
        self.recorder = recorder
    }

    /// Starts transmission immediately when no prefix read is required.
    func channelActive(context: ChannelHandlerContext) {
        if prefixReadLength == 0 {
            startScript(context: context)
        }
    }

    /// Buffers input until the configured prefix can be recorded.
    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        guard !started else {
            return
        }
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        guard pending.readableBytes >= prefixReadLength,
            let bytes = pending.readData(length: prefixReadLength)
        else {
            return
        }
        recorder.record(bytes)
        startScript(context: context)
    }

    /// Schedules every response chunk and the final channel closure.
    private func startScript(context: ChannelHandlerContext) {
        guard !started else {
            return
        }
        started = true
        let channel = context.channel
        let closeDelayMicros = self.closeDelayMicros
        let scheduleClose: @Sendable () -> Void = {
            if closeDelayMicros > 0 {
                channel.eventLoop.scheduleTask(
                    in: .microseconds(closeDelayMicros)
                ) {
                    channel.close(promise: nil)
                }
            } else {
                channel.close(promise: nil)
            }
        }
        guard !chunks.isEmpty else {
            scheduleClose()
            return
        }

        let lastChunkIndex = chunks.index(before: chunks.endIndex)
        var delay: Int64 = 0
        for (index, chunk) in chunks.enumerated() {
            if index > 0 {
                delay += interChunkDelayMicros
            }
            context.eventLoop.scheduleTask(
                in: .microseconds(delay)
            ) {
                guard channel.isActive else {
                    return
                }
                var buffer = channel.allocator.buffer(
                    capacity: chunk.count
                )
                buffer.writeBytes(chunk)
                if index == lastChunkIndex {
                    let writePromise = channel.eventLoop.makePromise(
                        of: Void.self
                    )
                    writePromise.futureResult.whenComplete { _ in
                        scheduleClose()
                    }
                    channel.writeAndFlush(
                        buffer,
                        promise: writePromise
                    )
                } else {
                    channel.writeAndFlush(
                        buffer,
                        promise: nil
                    )
                }
            }
        }
    }

    /// Closes the accepted channel after a pipeline failure.
    func errorCaught(
        context: ChannelHandlerContext,
        error _: Error
    ) {
        context.close(promise: nil)
    }
}
