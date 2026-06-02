import Foundation

/// Client for the device heartbeat service.
///
/// The heartbeat service sends periodic plist messages containing an
/// `Interval` field. Clients keep the session alive by replying with
/// `{"Command": "Polo"}` for each interval message.
public final class HeartbeatClient {
    private let connection: DeviceConnection

    /// Creates a heartbeat client over an existing service connection.
    ///
    /// The connection should come from `DeviceSession.startService(.heartbeat)`
    /// or an equivalent caller-provided transport.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Receives one heartbeat message and sends the matching response.
    ///
    /// - Returns: The heartbeat interval reported by the device.
    public func respondOnce() async throws -> UInt64 {
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

    /// Extracts an unsigned heartbeat interval from plist-compatible values.
    private func heartbeatInterval(from message: [String: Any]) -> UInt64? {
        if let interval = message["Interval"] as? UInt64 {
            return interval
        }
        if let interval = message["Interval"] as? UInt {
            return UInt64(interval)
        }
        if let interval = message["Interval"] as? Int, interval >= 0 {
            return UInt64(interval)
        }
        if let interval = message["Interval"] as? NSNumber {
            let value = interval.int64Value
            return value >= 0 ? UInt64(value) : nil
        }
        return nil
    }
}

/// Long-lived heartbeat responder.
///
/// Keep this object alive while performing tunnel-backed service operations.
/// It stops automatically on deinitialization, or callers can stop it
/// explicitly after the operation finishes.
public final class DeviceHeartbeat {
    private let client: HeartbeatClient
    private let lock = NSLock()
    private var responseTask: Task<Void, Never>?
    private var stopped = false

    init(client: HeartbeatClient) {
        self.client = client
    }

    deinit {
        stop()
    }

    /// Stops responding and closes the heartbeat connection.
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
        client.close()
    }

    /// Waits for the first beat, then starts the background response loop.
    func start(firstBeatTimeout: Duration) async throws {
        let firstBeatTask = Task {
            try await client.respondOnce()
        }

        do {
            _ = try await withHeartbeatTimeout(firstBeatTimeout) {
                try await firstBeatTask.value
            }
        } catch {
            firstBeatTask.cancel()
            client.close()
            throw error
        }

        let task = Task { [client] in
            while !Task.isCancelled {
                do {
                    _ = try await client.respondOnce()
                } catch {
                    break
                }
            }
            client.close()
        }

        guard setResponseTaskIfRunning(task) else {
            task.cancel()
            client.close()
            return
        }
    }

    /// Installs the response task if `stop()` has not already run.
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

/// Runs an async operation with a heartbeat-specific timeout.
private func withHeartbeatTimeout<T>(
    _ timeout: Duration,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RorkDeviceError.heartbeat("Timed out waiting for first beat.")
        }

        guard let result = try await group.next() else {
            throw RorkDeviceError.heartbeat("Timed out waiting for first beat.")
        }
        group.cancelAll()
        return result
    }
}
