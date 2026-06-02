import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix

/// SwiftNIO-backed byte stream used by concrete device transports.
///
/// Device protocols in this package are framed above a reliable byte stream,
/// while SwiftNIO delivers inbound data as arbitrary `ByteBuffer` chunks. This
/// adapter bridges those models by accumulating inbound bytes, fulfilling exact
/// reads for protocol parsers, and fulfilling short reads for SecureTransport.
final class NIODeviceConnection: DeviceConnection, PartialReceiveDeviceConnection {
    private let channel: Channel
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let handler: NIOByteStreamHandler
    private let lock = NSLock()
    private var closed = false

    /// Creates a connection around an initialized NIO channel.
    ///
    /// - Parameters:
    ///   - channel: Open channel whose pipeline contains `handler`.
    ///   - eventLoopGroup: Group that owns the channel's event loop. The
    ///     connection shuts this group down when it closes.
    ///   - handler: Inbound byte accumulator installed in the channel pipeline.
    init(channel: Channel, eventLoopGroup: MultiThreadedEventLoopGroup, handler: NIOByteStreamHandler) {
        self.channel = channel
        self.eventLoopGroup = eventLoopGroup
        self.handler = handler
    }

    /// Writes the complete buffer through the NIO channel.
    func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Receives exactly `byteCount` bytes from the accumulated inbound stream.
    func receive(exactly byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput("Cannot receive a negative byte count.")
        }
        guard byteCount > 0 else {
            return Data()
        }
        return try await handler.read(exactly: byteCount)
    }

    /// Receives the currently available inbound bytes up to `byteCount`.
    func receive(upTo byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput("Cannot receive a negative byte count.")
        }
        guard byteCount > 0 else {
            return Data()
        }
        return try await handler.read(upTo: byteCount)
    }

    /// Closes the channel and releases the connection-owned event loop group.
    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        handler.close()
        shutdownChannelAndEventLoopGroup()
    }

    deinit {
        close()
    }

    /// Performs blocking NIO shutdown away from the channel event loop.
    private func shutdownChannelAndEventLoopGroup() {
        let channel = channel
        let eventLoopGroup = eventLoopGroup
        let shutdown = {
            _ = try? channel.close().wait()
            try? eventLoopGroup.syncShutdownGracefully()
        }

        if channel.eventLoop.inEventLoop {
            Thread.detachNewThread(shutdown)
        } else {
            shutdown()
        }
    }
}

/// Inbound handler that turns arbitrary NIO reads into awaitable byte requests.
///
/// The handler keeps one FIFO queue of pending reads. Exact reads wait until the
/// requested count is buffered, while short reads complete as soon as at least
/// one byte is available.
final class NIOByteStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum ReadMode {
        case exact(Int)
        case upTo(Int)
    }

    private struct PendingRead {
        let mode: ReadMode
        let continuation: CheckedContinuation<Data, Error>
    }

    private enum Completion {
        case success(CheckedContinuation<Data, Error>, Data)
        case failure(CheckedContinuation<Data, Error>, Error)
    }

    private let lock = NSLock()
    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var pendingReads: [PendingRead] = []
    private var terminalError: Error?

    /// Waits for exactly `byteCount` buffered bytes.
    func read(exactly byteCount: Int) async throws -> Data {
        try await read(.exact(byteCount))
    }

    /// Waits for one or more buffered bytes, capped at `byteCount`.
    func read(upTo byteCount: Int) async throws -> Data {
        try await read(.upTo(byteCount))
    }

    /// Fails pending reads because the owning connection is closing explicitly.
    func close() {
        failPendingReads(with: RorkDeviceError.transport("Connection is closed."))
    }

    /// Appends inbound bytes and resumes any reads that can now complete.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        let completions: [Completion]

        lock.lock()
        buffer.writeBuffer(&inbound)
        completions = fulfillPendingReadsLocked()
        lock.unlock()

        resume(completions)
    }

    /// Fails outstanding reads when NIO reports a transport error.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failPendingReads(with: RorkDeviceError.transport(error.localizedDescription))
        context.close(promise: nil)
    }

    /// Fails outstanding reads when the peer closes before their buffers fill.
    func channelInactive(context: ChannelHandlerContext) {
        failPendingReads(with: RorkDeviceError.transport("Connection closed."))
    }

    /// Registers a read request or fulfills it immediately from buffered bytes.
    private func read(_ mode: ReadMode) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion: Completion?

            lock.lock()
            if let data = readBufferedDataLocked(for: mode) {
                completion = .success(continuation, data)
            } else if let terminalError {
                completion = .failure(continuation, terminalError)
            } else {
                pendingReads.append(PendingRead(mode: mode, continuation: continuation))
                completion = nil
            }
            lock.unlock()

            if let completion {
                resume([completion])
            }
        }
    }

    /// Marks the stream failed and drains all queued continuations.
    private func failPendingReads(with error: Error) {
        let completions: [Completion]

        lock.lock()
        if terminalError == nil {
            terminalError = error
        }
        completions = pendingReads.map { .failure($0.continuation, error) }
        pendingReads.removeAll()
        lock.unlock()

        resume(completions)
    }

    /// Reads bytes for the first queued waiters while enough data is buffered.
    private func fulfillPendingReadsLocked() -> [Completion] {
        var completions: [Completion] = []

        while let pendingRead = pendingReads.first,
              let data = readBufferedDataLocked(for: pendingRead.mode) {
            pendingReads.removeFirst()
            completions.append(.success(pendingRead.continuation, data))
        }

        return completions
    }

    /// Returns buffered data for a read mode when the mode can be satisfied.
    private func readBufferedDataLocked(for mode: ReadMode) -> Data? {
        switch mode {
        case let .exact(byteCount):
            guard buffer.readableBytes >= byteCount else {
                return nil
            }
            return buffer.readData(length: byteCount)
        case let .upTo(byteCount):
            guard buffer.readableBytes > 0 else {
                return nil
            }
            return buffer.readData(length: min(byteCount, buffer.readableBytes))
        }
    }

    /// Resumes continuations outside the lock to avoid re-entrancy deadlocks.
    private func resume(_ completions: [Completion]) {
        for completion in completions {
            switch completion {
            case let .success(continuation, data):
                continuation.resume(returning: data)
            case let .failure(continuation, error):
                continuation.resume(throwing: error)
            }
        }
    }
}
