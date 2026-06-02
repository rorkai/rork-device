import Foundation
import NIOCore
import NIOFoundationCompat

/// SwiftNIO-backed byte stream used by concrete device transports.
///
/// Device protocols in this package read from a reliable byte stream. SwiftNIO
/// delivers that stream as arbitrary `ByteBuffer` chunks.
///
/// This adapter uses `NIOAsyncChannel` to bridge those models. A long-lived pump
/// task drains the inbound async sequence with NIO back pressure, then fulfills
/// the imperative `receive(exactly:)` and `receive(upTo:)` calls used by protocol
/// parsers.
///
/// Writes go directly to the channel, so `send` completes only after the bytes
/// have been flushed to the socket.
final class NIODeviceConnection: DeviceConnection, PartialReceiveDeviceConnection {
    /// Error reported to callers once the owner closes the stream locally.
    static let closedError = RorkDeviceError.transport("Connection is closed.")

    /// Error reported when the peer closes before a read can be satisfied.
    static let peerClosedError = RorkDeviceError.transport("Connection closed.")

    /// Channel handle retained for outbound writes and prompt close.
    private let channel: Channel

    /// Serializes inbound reads and owns terminal close state for reads.
    private let coordinator: InboundReadCoordinator

    /// Long-lived task draining the channel's inbound async sequence.
    ///
    /// The task is retained so `close()` can cancel the pump immediately after
    /// marking the stream closed, instead of waiting for the channel teardown to
    /// wake the inbound iterator.
    private let pumpTask: Task<Void, Never>

    /// Guards `closedLocally` so close is observable from any thread.
    private let stateLock = NSLock()

    /// Tracks local close so it is rejected synchronously before `close()`
    /// returns, preventing late reads from draining still-buffered bytes.
    private var closedLocally = false

    /// Creates a connection around an async-wrapped NIO channel.
    ///
    /// - Parameter asyncChannel: Channel already wrapped with `NIOAsyncChannel`
    ///   on its event loop.
    init(asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) {
        let coordinator = InboundReadCoordinator()
        channel = asyncChannel.channel
        self.coordinator = coordinator
        pumpTask = Task {
            await runInboundPump(coordinator: coordinator, asyncChannel: asyncChannel)
        }
    }

    /// Writes the complete buffer through the NIO channel.
    func send(_ data: Data) async throws {
        try ensureOpen()
        guard !data.isEmpty else {
            return
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw normalizedStreamError(error)
        }
    }

    /// Receives exactly `byteCount` bytes from the accumulated inbound stream.
    func receive(exactly byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput("Cannot receive a negative byte count.")
        }
        guard byteCount > 0 else {
            return Data()
        }
        try ensureOpen()
        return try await coordinator.read(.exact(byteCount))
    }

    /// Receives the currently available inbound bytes up to `byteCount`.
    func receive(upTo byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput("Cannot receive a negative byte count.")
        }
        guard byteCount > 0 else {
            return Data()
        }
        try ensureOpen()
        return try await coordinator.read(.upTo(byteCount))
    }

    /// Closes the channel and fails any in-flight or future reads.
    func close() {
        stateLock.lock()
        let alreadyClosed = closedLocally
        closedLocally = true
        stateLock.unlock()

        guard !alreadyClosed else {
            return
        }

        channel.close(promise: nil)
        pumpTask.cancel()
        let coordinator = self.coordinator
        Task { await coordinator.finishClosing(with: NIODeviceConnection.closedError) }
    }

    deinit {
        close()
    }

    /// Ensures the owner has not already closed the stream.
    private func ensureOpen() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closedLocally {
            throw NIODeviceConnection.closedError
        }
    }
}

/// Shape of a pending read request handed to the inbound pump.
private enum ByteStreamReadKind: Sendable {
    /// Read must wait for exactly this many bytes.
    case exact(Int)

    /// Read may return any non-empty byte count up to this limit.
    case upTo(Int)
}

/// A suspended `receive` waiting for the pump to deliver bytes or an error.
private struct ByteStreamReadDemand {
    /// Read shape requested by the caller.
    let kind: ByteStreamReadKind

    /// Continuation resumed with bytes or a stream error.
    let continuation: CheckedContinuation<Data, Error>
}

/// Serializes imperative reads onto the channel's inbound async sequence.
///
/// Callers enqueue read demands here; the pump's reader loop pulls one demand at
/// a time, so the single inbound iterator is consumed in order. All terminal
/// state lives behind the actor so close, peer EOF, and transport failures
/// resolve every outstanding and future read exactly once.
private actor InboundReadCoordinator {
    /// Reads waiting for the reader loop to pick them up.
    private var readQueue: [ByteStreamReadDemand] = []

    /// Reader loop parked because no read demand was queued.
    private var readWaiter: CheckedContinuation<ByteStreamReadDemand?, Never>?

    /// Terminal error once the stream is closed locally, by EOF, or by NIO.
    private var closeError: Error?

    /// Enqueues a read and suspends until bytes or a terminal error arrive.
    func read(_ kind: ByteStreamReadKind) async throws -> Data {
        if let closeError {
            throw closeError
        }
        return try await withCheckedThrowingContinuation { continuation in
            let demand = ByteStreamReadDemand(kind: kind, continuation: continuation)
            if let waiter = readWaiter {
                readWaiter = nil
                waiter.resume(returning: demand)
            } else {
                readQueue.append(demand)
            }
        }
    }

    /// Returns the next queued read, or `nil` once the stream is terminal.
    func nextRead() async -> ByteStreamReadDemand? {
        if closeError != nil {
            return nil
        }
        if !readQueue.isEmpty {
            return readQueue.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            readWaiter = continuation
        }
    }

    /// Marks the stream terminal and resolves every queued read and the waiter.
    ///
    /// A read already handed to the reader loop is resolved by that loop when
    /// the inbound iterator ends, so this only drains reads still owned here.
    func finishClosing(with error: Error) {
        guard closeError == nil else {
            return
        }
        closeError = error

        let pendingReads = readQueue
        let parkedReader = readWaiter
        readQueue.removeAll()
        readWaiter = nil

        for demand in pendingReads {
            demand.continuation.resume(throwing: error)
        }
        parkedReader?.resume(returning: nil)
    }
}

/// Bridges the channel's inbound async sequence to the read coordinator.
///
/// `executeThenClose` keeps scoped ownership of the inbound stream and
/// guarantees the channel is closed once the reader loop finishes. When the loop
/// hits a terminal condition it closes the coordinator, and the trailing close
/// covers the case where the loop exits because the coordinator was closed.
private func runInboundPump(
    coordinator: InboundReadCoordinator,
    asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
) async {
    do {
        try await asyncChannel.executeThenClose { inbound, _ in
            await runInboundReader(coordinator: coordinator, inbound: inbound)
        }
    } catch {
        await coordinator.finishClosing(with: normalizedStreamError(error))
        return
    }

    await coordinator.finishClosing(with: NIODeviceConnection.closedError)
}

/// Drains inbound chunks on demand, fulfilling reads from a leftover buffer.
private func runInboundReader(
    coordinator: InboundReadCoordinator,
    inbound: NIOAsyncChannelInboundStream<ByteBuffer>
) async {
    var iterator = inbound.makeAsyncIterator()
    var leftover = ByteBufferAllocator().buffer(capacity: 0)

    while let demand = await coordinator.nextRead() {
        do {
            let data = try await readData(for: demand.kind, leftover: &leftover, iterator: &iterator)
            demand.continuation.resume(returning: data)
        } catch {
            demand.continuation.resume(throwing: error)
            await coordinator.finishClosing(with: error)
            break
        }
    }
}

/// Reads bytes for a single demand, pulling more chunks only when required.
private func readData(
    for kind: ByteStreamReadKind,
    leftover: inout ByteBuffer,
    iterator: inout NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
) async throws -> Data {
    switch kind {
    case let .exact(byteCount):
        while leftover.readableBytes < byteCount {
            guard let chunk = try await iterator.next() else {
                throw NIODeviceConnection.peerClosedError
            }
            leftover.writeImmutableBuffer(chunk)
        }
        let data = leftover.readData(length: byteCount) ?? Data()
        compact(&leftover)
        return data

    case let .upTo(byteCount):
        if leftover.readableBytes == 0 {
            guard let chunk = try await iterator.next() else {
                throw NIODeviceConnection.peerClosedError
            }
            leftover.writeImmutableBuffer(chunk)
        }
        let count = min(byteCount, leftover.readableBytes)
        let data = leftover.readData(length: count) ?? Data()
        compact(&leftover)
        return data
    }
}

/// Reclaims consumed storage so long-lived streams do not retain stale bytes.
private func compact(_ buffer: inout ByteBuffer) {
    if buffer.readableBytes == 0 {
        buffer = ByteBufferAllocator().buffer(capacity: 0)
    } else {
        buffer.discardReadBytes()
    }
}

/// Converts framework-level stream failures into the package transport error surface.
private func normalizedStreamError(_ error: Error) -> Error {
    if error is CancellationError {
        return NIODeviceConnection.closedError
    }
    if let channelError = error as? ChannelError {
        switch channelError {
        case .ioOnClosedChannel:
            return NIODeviceConnection.closedError
        default:
            break
        }
    }
    if error is RorkDeviceError {
        return error
    }
    return RorkDeviceError.transport(describeTransportError(error))
}
