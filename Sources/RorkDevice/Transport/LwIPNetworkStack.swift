import Foundation
import RorkDeviceLwIP

/// Serialized Swift adapter around the package's private lwIP C target.
///
/// lwIP's callback API requires every protocol operation and timer callback to
/// run on one execution context. All stack instances share this queue because
/// lwIP stores TCP protocol control blocks globally even when multiple network
/// interfaces are active.
final class LwIPNetworkStack: @unchecked Sendable {
    /// Queue identity used to avoid synchronous self-deadlock during teardown.
    private static let queueKey = DispatchSpecificKey<Void>()

    /// Process-wide lwIP execution context.
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "dev.rork.rork-device.lwip"
        )
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    /// Callback holder whose stable address is passed through the C boundary.
    private let outputSink: LwIPOutputSink

    /// Protects lifecycle state and the active Swift connection states.
    private let stateLock = NSLock()

    /// Swift state retained for each queue-confined C connection wrapper.
    private var connectionStates: [
        ObjectIdentifier: LwIPConnectionState
    ] = [:]

    /// C network stack, cleared exactly once during closure.
    private var stack: OpaquePointer?

    /// Timer that advances TCP retransmission and keepalive state.
    private var timer: DispatchSourceTimer?

    /// Creates an IPv6-only userspace stack.
    ///
    /// - Parameters:
    ///   - localAddress: Host-side IPv6 address assigned by CoreDevice.
    ///   - maximumTransmissionUnit: Maximum complete IPv6 packet size.
    ///   - output: Synchronous callback receiving packets emitted toward the
    ///     device. The callback must copy or retain `Data` if it uses it later.
    /// - Throws: `RorkDeviceError.invalidInput` for malformed configuration or
    ///   `RorkDeviceError.transport` when lwIP cannot allocate its interface.
    init(
        localAddress: String,
        maximumTransmissionUnit: UInt16,
        output: @escaping @Sendable (Data) -> Void
    ) throws {
        guard maximumTransmissionUnit >= 1_280 else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace network requires an MTU of at least 1280."
            )
        }
        let localAddressBytes = try ipv6AddressBytes(
            localAddress,
            invalidMessage:
                "CoreDevice userspace network requires a valid host IPv6 address."
        )
        outputSink = LwIPOutputSink(output: output)

        let outputContext = Unmanaged.passUnretained(outputSink)
            .toOpaque()
        stack = Self.performSync {
            localAddressBytes.withUnsafeBytes { bytes in
                rork_lwip_stack_create(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    maximumTransmissionUnit,
                    rorkLwIPOutputCallback,
                    outputContext
                )
            }
        }
        guard stack != nil else {
            throw RorkDeviceError.transport(
                "Could not create the CoreDevice userspace IPv6 stack."
            )
        }
        startTimer()
    }

    deinit {
        close()
    }

    /// Opens one TCP connection through the userspace IPv6 interface.
    func connect(
        to remoteAddress: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> DeviceConnection {
        guard port > 0 else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace network requires a nonzero device port."
            )
        }
        let remoteAddressBytes = try ipv6AddressBytes(
            remoteAddress,
            invalidMessage:
                "CoreDevice userspace network requires a valid device IPv6 address."
        )
        let state = LwIPConnectionState()
        let callbackContext = Unmanaged.passUnretained(state).toOpaque()

        let pointer: OpaquePointer? = Self.performSync {
            guard let stack = currentStack() else {
                return nil
            }
            return remoteAddressBytes.withUnsafeBytes { bytes in
                rork_lwip_connection_create(
                    stack,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    port,
                    rorkLwIPConnectionCallback,
                    callbackContext
                )
            }
        }
        guard let pointer else {
            throw RorkDeviceError.transport(
                "Could not start the CoreDevice userspace TCP connection."
            )
        }

        let handle = LwIPConnectionHandle(pointer: pointer)
        stateLock.withLock {
            connectionStates[ObjectIdentifier(handle)] = state
        }
        let connection = LwIPDeviceConnection(
            stack: self,
            handle: handle,
            state: state
        )
        do {
            try await state.waitUntilConnected(timeout: timeout)
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Delivers one packet received from the CoreDevice tunnel.
    func receivePacket(_ packet: Data) async throws {
        try CDTunnelProtocol.validatePacket(
            packet,
            diagnosticName: "CoreDevice userspace network"
        )
        let result: Int32 = await withCheckedContinuation { continuation in
            Self.queue.async { [weak self] in
                guard let stack = self?.currentStack() else {
                    continuation.resume(returning: -11)
                    return
                }
                let result = packet.withUnsafeBytes { bytes in
                    rork_lwip_stack_input(
                        stack,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count
                    )
                }
                continuation.resume(returning: result)
            }
        }
        guard result == 0 else {
            throw lwIPTransportError(
                operation: "receive an IPv6 packet",
                code: result
            )
        }
    }

    /// Closes the stack and fails every connection still waiting on it.
    ///
    /// - Parameter error: Failure that stopped the packet data plane. Explicit
    ///   closure uses the stable generic error when no underlying cause exists.
    func close(with error: Error? = nil) {
        let states: [LwIPConnectionState] = stateLock.withLock {
            timer?.cancel()
            timer = nil
            let states = Array(connectionStates.values)
            connectionStates.removeAll()
            return states
        }
        let terminalError = error ?? RorkDeviceError.transport(
            "CoreDevice userspace network closed."
        )
        states.forEach { $0.finish(with: terminalError) }

        Self.performSync {
            stateLock.withLock {
                guard let stack else {
                    return
                }
                rork_lwip_stack_destroy(stack)
                self.stack = nil
            }
        }
    }

    /// Writes bytes into one lwIP TCP connection.
    fileprivate func write(
        _ data: Data,
        to handle: LwIPConnectionHandle
    ) async throws -> Int {
        let result: Int? = await withCheckedContinuation { continuation in
            Self.queue.async {
                let result = handle.withConnection { pointer in
                    data.withUnsafeBytes { bytes in
                        rork_lwip_connection_write(
                            pointer,
                            bytes.bindMemory(to: UInt8.self).baseAddress,
                            bytes.count
                        )
                    }
                }
                continuation.resume(returning: result)
            }
        }
        guard let result else {
            throw RorkDeviceError.transport(
                "CoreDevice userspace TCP connection is closed."
            )
        }
        guard result >= 0 else {
            throw lwIPTransportError(
                operation: "write TCP data",
                code: Int32(result)
            )
        }
        return result
    }

    /// Returns consumed receive capacity to lwIP's advertised TCP window.
    fileprivate func acknowledgeReceivedBytes(
        _ count: Int,
        on handle: LwIPConnectionHandle
    ) {
        Self.queue.async {
            handle.withConnection { pointer in
                rork_lwip_connection_received(pointer, count)
            }
        }
    }

    /// Closes and releases one C connection wrapper.
    fileprivate func destroyConnection(
        _ handle: LwIPConnectionHandle,
        state: LwIPConnectionState
    ) {
        _ = stateLock.withLock {
            connectionStates.removeValue(
                forKey: ObjectIdentifier(handle)
            )
        }
        Self.queue.async {
            handle.destroyConnection()
            // Keep the callback target alive until C has detached and released
            // every reference that can use its unretained context pointer.
            _ = state
        }
    }

    /// Returns the current stack pointer while the caller owns lifecycle access.
    private func currentStack() -> OpaquePointer? {
        stateLock.withLock { stack }
    }

    /// Starts periodic processing for TCP retransmission and keepalive timers.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let stack = self?.currentStack() else {
                return
            }
            rork_lwip_stack_poll(stack)
        }
        stateLock.withLock {
            self.timer = timer
        }
        timer.resume()
    }

    /// Runs a synchronous operation on lwIP's queue without reentering it.
    private static func performSync<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}

/// Queue-confined owner for one C connection wrapper.
private final class LwIPConnectionHandle: @unchecked Sendable {
    /// Opaque wrapper while the connection remains active.
    ///
    /// This value is read and cleared only on the process-wide lwIP queue.
    /// Confinement prevents queued operations from dereferencing the wrapper
    /// after its C storage has been released.
    private var pointer: OpaquePointer?

    /// Creates a stable pointer owner for one Swift connection.
    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Performs an operation only while the C wrapper remains alive.
    ///
    /// - Parameter operation: Synchronous operation executed on the lwIP queue.
    /// - Returns: The operation result, or `nil` after destruction.
    func withConnection<Result>(
        _ operation: (OpaquePointer) -> Result
    ) -> Result? {
        guard let pointer else {
            return nil
        }
        return operation(pointer)
    }

    /// Clears and releases the C wrapper exactly once.
    ///
    /// Clearing the pointer before calling the destructor ensures every later
    /// queued operation observes the closed lifecycle state.
    func destroyConnection() {
        guard let pointer else {
            return
        }
        self.pointer = nil
        rork_lwip_connection_destroy(pointer)
    }
}

/// Stable callback target used by the lwIP network-interface shim.
private final class LwIPOutputSink: @unchecked Sendable {
    /// Packet callback supplied by the owning Swift transport.
    private let output: @Sendable (Data) -> Void

    /// Creates a callback holder with reference-stable identity.
    init(output: @escaping @Sendable (Data) -> Void) {
        self.output = output
    }

    /// Copies one packet out of the synchronous C callback.
    func emit(_ packet: UnsafePointer<UInt8>, length: Int) {
        output(Data(bytes: packet, count: length))
    }
}

/// Mutable async state associated with one lwIP TCP control block.
final class LwIPConnectionState: @unchecked Sendable {
    /// Async sleep implementation used by the handshake timeout task.
    typealias TimeoutSleep = @Sendable (Duration) async throws -> Void

    /// Protects all fields because C callbacks and async callers use different executors.
    private let lock = NSLock()

    /// Sleep operation used to enforce the connection deadline.
    private let timeoutSleep: TimeoutSleep

    /// Buffered bytes not yet consumed by `receive(exactly:)`.
    private var inbound = Data()

    /// Whether the TCP handshake completed.
    private var isConnected = false

    /// Final failure or closure observed for this connection.
    private var terminalError: Error?

    /// Continuation waiting for the initial TCP handshake.
    private var connectionWaiter: CheckedContinuation<Void, Error>?

    /// Cancellable task enforcing the initial TCP handshake deadline.
    private var connectionTimeoutTask: Task<Void, Never>?

    /// Exact-read continuation, limited to one active protocol reader.
    private var receiveWaiter: (
        count: Int,
        continuation: CheckedContinuation<Data, Error>
    )?

    /// Monotonic token advanced whenever lwIP may accept more send data.
    private var writableGeneration: UInt64 = 0

    /// Writers suspended after exhausting lwIP's current send window.
    private var writableWaiters: [(
        generation: UInt64,
        continuation: CheckedContinuation<Void, Error>
    )] = []

    /// Creates connection state with a configurable deadline clock.
    ///
    /// The default uses Swift's continuous clock. Supplying another operation
    /// allows deterministic deadline control without changing connection-state
    /// transitions.
    init(
        timeoutSleep: @escaping TimeoutSleep = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.timeoutSleep = timeoutSleep
    }

    /// Waits for the three-way TCP handshake or fails it after `timeout`.
    func waitUntilConnected(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isConnected {
                lock.unlock()
                continuation.resume()
                return
            }
            if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
                return
            }
            precondition(
                connectionWaiter == nil,
                "Only one task may await an lwIP connection handshake."
            )
            connectionWaiter = continuation
            let timeoutSleep = self.timeoutSleep
            connectionTimeoutTask = Task { [weak self] in
                do {
                    try await timeoutSleep(timeout)
                } catch {
                    return
                }
                self?.finishConnectingAfterTimeout()
            }
            lock.unlock()
        }
    }

    /// Receives currently available bytes up to the requested count.
    func receive(upTo count: Int) async throws -> Data {
        guard count >= 0 else {
            throw RorkDeviceError.invalidInput(
                "Receive byte count cannot be negative."
            )
        }
        if count == 0 {
            return Data()
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            lock.lock()
            if !inbound.isEmpty {
                let receivedCount = min(count, inbound.count)
                let data = Data(inbound.prefix(receivedCount))
                inbound.removeFirst(receivedCount)
                lock.unlock()
                continuation.resume(returning: data)
                return
            }
            if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
                return
            }
            precondition(
                receiveWaiter == nil,
                "DeviceConnection supports one active reader."
            )
            receiveWaiter = (count, continuation)
            lock.unlock()
        }
    }

    /// Returns the current send-window generation before attempting a write.
    func currentWritableGeneration() -> UInt64 {
        lock.withLock { writableGeneration }
    }

    /// Waits until a callback indicates additional TCP send capacity.
    func waitUntilWritable(after generation: UInt64) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if writableGeneration != generation {
                lock.unlock()
                continuation.resume()
                return
            }
            if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
                return
            }
            writableWaiters.append((generation, continuation))
            lock.unlock()
        }
    }

    /// Applies an event emitted synchronously by the C shim.
    func handle(
        _ event: rork_lwip_connection_event_t,
        data: Data?,
        errorCode: Int32
    ) {
        switch event {
        case RORK_LWIP_CONNECTION_CONNECTED:
            handleConnected()
        case RORK_LWIP_CONNECTION_DATA:
            if let data {
                handleReceived(data)
            }
        case RORK_LWIP_CONNECTION_WRITABLE:
            handleWritable()
        case RORK_LWIP_CONNECTION_CLOSED:
            finish(
                with: RorkDeviceError.transport(
                    "CoreDevice userspace TCP connection closed."
                )
            )
        case RORK_LWIP_CONNECTION_ERROR:
            finish(
                with: lwIPTransportError(
                    operation: "maintain the TCP connection",
                    code: errorCode
                )
            )
        default:
            finish(
                with: RorkDeviceError.protocolViolation(
                    "lwIP emitted an unknown connection event."
                )
            )
        }
    }

    /// Fails every pending operation and makes the state terminal.
    func finish(with error: Error) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let connectionWaiter = self.connectionWaiter
        self.connectionWaiter = nil
        let connectionTimeoutTask = self.connectionTimeoutTask
        self.connectionTimeoutTask = nil
        let receiveWaiter = self.receiveWaiter
        self.receiveWaiter = nil
        let writableWaiters = self.writableWaiters
        self.writableWaiters.removeAll()
        lock.unlock()

        connectionTimeoutTask?.cancel()
        connectionWaiter?.resume(throwing: error)
        receiveWaiter?.continuation.resume(throwing: error)
        writableWaiters.forEach {
            $0.continuation.resume(throwing: error)
        }
    }

    /// Completes the handshake waiter exactly once.
    func handleConnected() {
        lock.lock()
        guard terminalError == nil, !isConnected else {
            lock.unlock()
            return
        }
        isConnected = true
        let waiter = connectionWaiter
        connectionWaiter = nil
        let timeoutTask = connectionTimeoutTask
        connectionTimeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        waiter?.resume()
    }

    /// Buffers received data and satisfies an exact read when enough is present.
    private func handleReceived(_ data: Data) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        inbound.append(data)
        guard let waiter = receiveWaiter else {
            lock.unlock()
            return
        }
        let receivedCount = min(waiter.count, inbound.count)
        let result = Data(inbound.prefix(receivedCount))
        inbound.removeFirst(receivedCount)
        receiveWaiter = nil
        lock.unlock()
        waiter.continuation.resume(returning: result)
    }

    /// Wakes senders that observed an exhausted TCP send window.
    private func handleWritable() {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        writableGeneration &+= 1
        let waiters = writableWaiters
        writableWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.continuation.resume() }
    }

    /// Converts an unfinished handshake into a terminal timeout.
    private func finishConnectingAfterTimeout() {
        lock.lock()
        guard !isConnected,
              terminalError == nil,
              let waiter = connectionWaiter else {
            lock.unlock()
            return
        }
        let error = RorkDeviceError.transport(
            "Timed out opening the CoreDevice userspace TCP connection."
        )
        terminalError = error
        connectionWaiter = nil
        connectionTimeoutTask = nil
        lock.unlock()
        waiter.resume(throwing: error)
    }
}

/// `DeviceConnection` implementation backed by one lwIP TCP control block.
private final class LwIPDeviceConnection:
    DeviceConnection,
    PartialReceiveDeviceConnection,
    @unchecked Sendable
{
    /// Stack that owns and serializes the C connection wrapper.
    private let stack: LwIPNetworkStack

    /// Sendable owner of the C connection wrapper.
    private let handle: LwIPConnectionHandle

    /// Callback-driven connection state.
    private let state: LwIPConnectionState

    /// Writer that serializes complete `send(_:)` calls.
    private let writer: LwIPConnectionWriter

    /// Protects idempotent C-wrapper destruction.
    private let closeLock = NSLock()

    /// Whether this Swift wrapper has released its C connection.
    private var isClosed = false

    /// Creates a connection after the C wrapper has started its handshake.
    init(
        stack: LwIPNetworkStack,
        handle: LwIPConnectionHandle,
        state: LwIPConnectionState
    ) {
        self.stack = stack
        self.handle = handle
        self.state = state
        writer = LwIPConnectionWriter(
            stack: stack,
            handle: handle,
            state: state
        )
    }

    deinit {
        close()
    }

    /// Sends the entire buffer with lwIP send-window backpressure.
    func send(_ data: Data) async throws {
        try await writer.send(data)
    }

    /// Reads exactly `byteCount` bytes and reopens the corresponding TCP window.
    func receive(exactly byteCount: Int) async throws -> Data {
        var data = Data()
        while data.count < byteCount {
            data.append(
                try await state.receive(
                    upTo: byteCount - data.count
                )
            )
        }
        stack.acknowledgeReceivedBytes(data.count, on: handle)
        return data
    }

    /// Reads at least one currently available byte up to `byteCount`.
    func receive(upTo byteCount: Int) async throws -> Data {
        let data = try await state.receive(upTo: byteCount)
        stack.acknowledgeReceivedBytes(data.count, on: handle)
        return data
    }

    /// Closes the TCP control block and resumes pending operations with an error.
    func close() {
        let shouldClose = closeLock.withLock {
            guard !isClosed else {
                return false
            }
            isClosed = true
            return true
        }
        guard shouldClose else {
            return
        }
        state.finish(
            with: RorkDeviceError.transport(
                "CoreDevice userspace TCP connection closed."
            )
        )
        stack.destroyConnection(handle, state: state)
    }
}

/// Serializes complete sends while still allowing receive operations to proceed.
private actor LwIPConnectionWriter {
    /// Stack that accepts data into lwIP's TCP send buffer.
    private let stack: LwIPNetworkStack

    /// Sendable owner of the C connection wrapper receiving writes.
    private let handle: LwIPConnectionHandle

    /// Callback state used to await additional send-window capacity.
    private let state: LwIPConnectionState

    /// Whether another actor task currently owns the send slot.
    private var isWriteInProgress = false

    /// Senders waiting in arrival order.
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a writer for one TCP connection.
    init(
        stack: LwIPNetworkStack,
        handle: LwIPConnectionHandle,
        state: LwIPConnectionState
    ) {
        self.stack = stack
        self.handle = handle
        self.state = state
    }

    /// Copies all bytes into lwIP, waiting when its send window is full.
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        await acquireWriteSlot()
        defer {
            releaseWriteSlot()
        }

        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let generation = state.currentWritableGeneration()
            let remaining = Data(data.dropFirst(offset))
            let written = try await stack.write(
                remaining,
                to: handle
            )
            if written == 0 {
                try await state.waitUntilWritable(after: generation)
                continue
            }
            offset += written
        }
    }

    /// Suspends until this sender exclusively owns the connection's write slot.
    private func acquireWriteSlot() async {
        guard isWriteInProgress else {
            isWriteInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    /// Transfers the write slot to the next sender or marks it as free.
    private func releaseWriteSlot() {
        guard !writeWaiters.isEmpty else {
            isWriteInProgress = false
            return
        }
        writeWaiters.removeFirst().resume()
    }
}

/// C callback that copies one emitted IPv6 packet into Swift-owned memory.
private func rorkLwIPOutputCallback(
    _ context: UnsafeMutableRawPointer?,
    _ packet: UnsafePointer<UInt8>?,
    _ length: Int
) {
    guard let context, let packet else {
        return
    }
    Unmanaged<LwIPOutputSink>
        .fromOpaque(context)
        .takeUnretainedValue()
        .emit(packet, length: length)
}

/// C callback that synchronously records TCP state and payload events.
private func rorkLwIPConnectionCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: rork_lwip_connection_event_t,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int,
    _ errorCode: Int32
) {
    guard let context else {
        return
    }
    let data = bytes.map { Data(bytes: $0, count: length) }
    Unmanaged<LwIPConnectionState>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handle(event, data: data, errorCode: errorCode)
}

/// Adds operation context to an opaque lwIP status code.
private func lwIPTransportError(
    operation: String,
    code: Int32
) -> RorkDeviceError {
    .transport("Could not \(operation) through lwIP (error \(code)).")
}
