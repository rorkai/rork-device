import Foundation

/// Client for the device's AMFI Lockdown service.
///
/// The service controls the Developer Mode setup flow introduced in iOS 16.
/// This client currently exposes only the non-destructive reveal operation,
/// which makes the Developer Mode setting visible without enabling it,
/// restarting the device, or confirming the post-restart prompt.
final class DeveloperModeClient {
    /// Stable error returned when the AMFI response exceeds its deadline.
    private static let timeoutError = RorkDeviceError.transport(
        "Developer Mode reveal timed out."
    )

    /// Connected `com.apple.amfi.lockdown` service stream.
    private let connection: DeviceConnection

    /// Creates a client over an already-started AMFI service connection.
    ///
    /// The caller retains ownership of the connection and is responsible for
    /// closing it after the operation completes.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Makes the Developer Mode setting visible on the connected device.
    ///
    /// iOS reports device-side failures in an `Error` field and successful
    /// requests with a `success` field. A response containing neither is
    /// rejected because it does not establish whether the setting was revealed.
    func reveal() async throws {
        try await PropertyListMessageFramer.send(
            ["action": 0],
            to: connection
        )
        let response = try await PropertyListMessageFramer.receive(
            from: connection
        )

        if let message = response.string("Error") {
            throw RorkDeviceError.lockdown(
                "Developer Mode reveal failed: \(message)"
            )
        }
        guard response.bool("success") == true else {
            throw RorkDeviceError.protocolViolation(
                "Developer Mode reveal response did not report success."
            )
        }
    }

    /// Makes the setting visible or fails after the supplied duration.
    ///
    /// The timeout closes the AMFI service connection before returning so a
    /// pending receive cannot outlive the operation.
    ///
    /// - Parameter timeout: Maximum time to wait for the AMFI response.
    /// - Throws: A transport timeout or any error produced by `reveal()`.
    func reveal(timeout: Duration) async throws {
        let worker = DeveloperModeRevealWorker(client: self)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [worker] in
                        try await worker.reveal()
                    }
                    group.addTask { [worker] in
                        try await Task.sleep(for: timeout)
                        worker.markTimedOutAndClose()
                        throw Self.timeoutError
                    }

                    defer {
                        group.cancelAll()
                    }
                    _ = try await group.next()
                }
            } onCancel: {
                worker.close()
            }
            if worker.didTimeOut {
                throw Self.timeoutError
            }
        } catch {
            if worker.didTimeOut {
                throw Self.timeoutError
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Closes the underlying AMFI connection.
    func close() {
        connection.close()
    }
}

/// Shares one Developer Mode reveal client across racing timeout tasks.
///
/// `DeviceConnection.close()` is thread-safe and interrupts pending reads, so
/// the worker may close the stream from the timeout or cancellation path while
/// the operation task is receiving a response.
final class DeveloperModeRevealWorker: @unchecked Sendable {
    /// Terminal state shared by the operation and timeout tasks.
    private enum Outcome {
        /// Neither task has completed the reveal.
        case pending

        /// The AMFI operation completed with a response or protocol error.
        case completed

        /// The timeout task closed the AMFI connection first.
        case timedOut
    }

    /// Client performing the AMFI protocol exchange.
    private let client: DeveloperModeClient

    /// Protects the timeout marker shared by the racing tasks.
    private let lock = NSLock()

    /// First terminal outcome observed by the racing tasks.
    private var outcome = Outcome.pending

    /// Creates a worker that owns one reveal client's concurrent lifecycle.
    init(client: DeveloperModeClient) {
        self.client = client
    }

    /// Reports whether the timeout path won the race.
    var didTimeOut: Bool {
        lock.withLock {
            if case .timedOut = outcome {
                return true
            }
            return false
        }
    }

    /// Performs the AMFI request on the operation task.
    func reveal() async throws {
        do {
            try await client.reveal()
            markCompleted()
        } catch {
            markCompleted()
            throw error
        }
    }

    /// Marks the timeout before closing the connection that may be receiving.
    func markTimedOutAndClose() {
        let shouldClose = lock.withLock {
            guard case .pending = outcome else {
                return false
            }
            outcome = .timedOut
            return true
        }
        if shouldClose {
            close()
        }
    }

    /// Closes the AMFI connection to release any pending operation.
    func close() {
        client.close()
    }

    /// Records AMFI completion without replacing an earlier timeout.
    private func markCompleted() {
        lock.withLock {
            guard case .pending = outcome else {
                return
            }
            outcome = .completed
        }
    }
}
