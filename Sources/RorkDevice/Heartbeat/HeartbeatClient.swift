import Foundation

/// Client for the device heartbeat service.
///
/// The heartbeat service sends periodic property-list messages containing an
/// `Interval` field. Clients keep the surrounding Lockdown service session
/// usable by replying with a binary property list containing
/// `{"Command": "Polo"}` for each interval message.
public final class HeartbeatClient {
    /// Service connection returned by `com.apple.mobile.heartbeat`.
    private let connection: DeviceConnection

    /// Creates a heartbeat client over an existing service connection.
    ///
    /// The connection should come from `DeviceSession.startService(.heartbeat)`
    /// or an equivalent caller-provided transport.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Receives the next heartbeat message and sends the matching response.
    ///
    /// A normal heartbeat message includes an `Interval` value measured in
    /// seconds. The client answers with the `Polo` command and returns that
    /// interval as a Swift `Duration` so callers do not need to work with raw
    /// protocol integers.
    ///
    /// - Returns: The heartbeat interval reported by the device.
    public func respondToNextMessage() async throws -> Duration {
        let message = try await PropertyListMessageFramer.receive(from: connection)
        if let interval = heartbeatInterval(from: message) {
            try await PropertyListMessageFramer.send(
                ["Command": "Polo"],
                to: connection,
                format: .binary
            )
            return interval
        }

        if message.string("Command") == "SleepyTime" {
            throw RorkDeviceError.heartbeat("Device reported SleepyTime.")
        }

        throw RorkDeviceError.heartbeat("Response missing Interval.")
    }

    /// Closes the heartbeat connection.
    public func close() {
        connection.close()
    }

    /// Extracts a heartbeat interval from property-list-compatible scalar values.
    private func heartbeatInterval(from message: [String: Any]) -> Duration? {
        if let interval = message["Interval"] as? UInt64 {
            return duration(seconds: interval)
        }
        if let interval = message["Interval"] as? UInt {
            return duration(seconds: UInt64(interval))
        }
        if let interval = message["Interval"] as? Int, interval >= 0 {
            return .seconds(Int64(interval))
        }
        if let interval = message["Interval"] as? NSNumber {
            let value = interval.int64Value
            return value >= 0 ? .seconds(value) : nil
        }
        return nil
    }

    /// Converts an unsigned protocol value into a Swift duration.
    private func duration(seconds: UInt64) -> Duration? {
        guard seconds <= UInt64(Int64.max) else {
            return nil
        }
        return .seconds(Int64(seconds))
    }
}

/// Retained heartbeat responder.
///
/// Keep this object alive while performing tunnel-backed service operations
/// such as AFC uploads or InstallationProxy installs. The responder owns the
/// heartbeat service connection and automatically replies to each heartbeat
/// message until `stop()` is called or the object is released.
///
/// The responder may be retained across tasks. It performs protocol reads and
/// replies on one internal task, while `stop()` may be called from any task to
/// cancel that work and close the connection. Repeated calls to `stop()` are
/// safe.
public final class DeviceHeartbeat: @unchecked Sendable {
    /// Sendable worker that owns the heartbeat protocol client.
    private let worker: HeartbeatResponseWorker

    /// Protects lifecycle state that can be touched by `stop()` and startup.
    private let lock = NSLock()

    /// Background responder task installed after the first successful message.
    private var responseTask: Task<Void, Never>?

    /// Whether the responder has been explicitly stopped.
    private var stopped = false

    /// Creates a retained heartbeat responder around a protocol client.
    init(client: HeartbeatClient) {
        worker = HeartbeatResponseWorker(client: client)
    }

    deinit {
        stop()
    }

    /// Stops responding and closes the heartbeat connection.
    ///
    /// Calling this method more than once is safe. The responder also stops from
    /// `deinit`, but explicit shutdown is useful when callers switch devices or
    /// replace an active session.
    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let task = responseTask
        responseTask = nil
        lock.unlock()

        task?.cancel()
        worker.close()
    }

    /// Waits for the first heartbeat message, then starts the response loop.
    func start(firstMessageTimeout: Duration) async throws {
        let firstMessageTask = Task { [worker] in
            try await worker.respondToNextMessage()
        }

        do {
            _ = try await withHeartbeatTimeout(firstMessageTimeout) {
                try await firstMessageTask.value
            }
        } catch {
            firstMessageTask.cancel()
            worker.close()
            throw error
        }

        let task = Task { [worker] in
            while !Task.isCancelled {
                do {
                    _ = try await worker.respondToNextMessage()
                } catch {
                    break
                }
            }
            worker.close()
        }

        guard setResponseTaskIfRunning(task) else {
            task.cancel()
            worker.close()
            return
        }
    }

    /// Installs the response task unless the responder was stopped meanwhile.
    private func setResponseTaskIfRunning(_ task: Task<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            return false
        }
        responseTask = task
        return true
    }
}

/// Task-safe owner of the heartbeat service connection.
///
/// Exactly one startup or response-loop task calls
/// `respondToNextMessage()`. The lifecycle owner may call `close()` from
/// another executor to interrupt that task, matching the thread-safe,
/// idempotent closure contract of package-created device connections.
private final class HeartbeatResponseWorker: @unchecked Sendable {
    /// Protocol client used exclusively by the response task.
    private let client: HeartbeatClient

    /// Creates a worker that takes responsibility for the client lifecycle.
    init(client: HeartbeatClient) {
        self.client = client
    }

    /// Receives and answers one heartbeat message.
    func respondToNextMessage() async throws -> Duration {
        try await client.respondToNextMessage()
    }

    /// Closes the service connection to interrupt pending protocol work.
    func close() {
        client.close()
    }
}

/// Runs an async operation with a heartbeat-specific timeout.
///
/// Heartbeat startup should fail promptly if the device never sends the initial
/// interval message. This helper races the operation against `Task.sleep` and
/// cancels the losing task.
private func withHeartbeatTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RorkDeviceError.heartbeat("Timed out waiting for the first heartbeat message.")
        }

        guard let result = try await group.next() else {
            throw RorkDeviceError.heartbeat("Timed out waiting for the first heartbeat message.")
        }
        group.cancelAll()
        return result
    }
}
