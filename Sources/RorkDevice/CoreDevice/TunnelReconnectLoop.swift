import Foundation

/// Keeps a userspace tunnel alive by re-establishing it whenever it drops.
///
/// `tunnel start --reconnect` runs establish/serve cycles through this engine
/// instead of exiting when the packet network dies. The engine owns retry
/// scheduling and lifecycle reporting; connecting, trust, and serving stay in
/// the injected cycle so the engine remains deterministic under test.
///
/// Two rules encode the Stage 2 field lessons:
///
/// - Backoff restarts only after a cycle reports readiness, so an outage is
///   paced as one growing schedule instead of hammering usbmux, while a healthy
///   tunnel that later drops recovers quickly again.
/// - The engine never abandons a cycle from the outside. While enrollment
///   waits on the user's Trust approval there is no timer that could tear the
///   tunnel down mid-approval; only the cycle itself decides when it failed.
public enum TunnelReconnectLoop {
    /// Lifecycle transitions reported while the loop keeps a tunnel alive.
    public enum Event: Equatable, Sendable {
        /// A tunnel that had reported readiness died with the given reason.
        case tunnelLost(reason: String)

        /// The next establishment attempt starts after the given delay.
        ///
        /// `reason` carries the most recent failure so consumers can surface
        /// the true root cause while the loop is still converging.
        case reestablishing(attempt: Int, delay: Duration, reason: String)
    }

    /// How a reattach wait ended.
    public enum ReattachWaitOutcome: Equatable, Sendable {
        /// A matching device attached before the delay elapsed.
        case reattached

        /// The full delay elapsed without a matching attach event.
        case waited
    }

    /// Runs establish/serve cycles until one closes cleanly or a wait fails.
    ///
    /// Every cycle failure is retried: the unrecoverable startup conditions
    /// (unparsable flags, unreadable identity file) fail before the loop is
    /// entered, and everything after that depends on the device environment,
    /// which can always heal. A clean cycle return means the tunnel was closed
    /// deliberately, so the loop returns with it.
    ///
    /// - Parameters:
    ///   - backoff: Delay schedule for attempts after a failure. The attempt
    ///     position resets each time a cycle reports readiness.
    ///   - waitBeforeAttempt: Waits the scheduled delay before a retry.
    ///     Production short-circuits the wait when the device reattaches;
    ///     a thrown error (such as cancellation) stops the loop.
    ///   - emit: Receives lifecycle events in occurrence order.
    ///   - establishAndServe: Establishes one tunnel, calls `onReady` once it
    ///     accepts clients, and returns when the tunnel closes cleanly or
    ///     throws when it fails or is lost.
    public static func run(
        backoff: Backoff,
        waitBeforeAttempt: (Duration) async throws -> Void,
        emit: (Event) -> Void,
        establishAndServe: (_ onReady: @escaping @Sendable () -> Void) async throws -> Void
    ) async throws {
        var attempt = 0
        while true {
            let becameReady = ReadyFlag()
            let reason: String
            do {
                try await establishAndServe {
                    becameReady.set()
                }
                return
            } catch {
                // Cancellation is a deliberate shutdown, not a tunnel
                // failure: propagate it without a lifecycle event so the
                // stdout stream never announces a retry that cannot happen.
                if error is CancellationError {
                    throw error
                }
                reason = String(describing: error)
                if becameReady.isSet {
                    attempt = 0
                    emit(.tunnelLost(reason: reason))
                }
            }

            attempt += 1
            let delay = backoff.delay(beforeAttempt: attempt)
            emit(.reestablishing(attempt: attempt, delay: delay, reason: reason))
            try await waitBeforeAttempt(delay)
        }
    }

    /// Waits up to `delay`, ending early when a matching device attaches.
    ///
    /// The reconnect loop calls this between attempts so a replugged phone is
    /// retried immediately instead of after the rest of an exponential delay.
    /// A failing event stream (usbmuxd restarting, socket denied) downgrades
    /// the wait to a plain sleep — reattach detection is an accelerator, never
    /// a requirement.
    ///
    /// - Parameters:
    ///   - deviceIdentifier: Device to watch for, or `nil` to accept the first
    ///     attach event of any device.
    ///   - delay: Upper bound on the wait.
    ///   - deviceEvents: Opens a fresh attach/detach event stream.
    ///   - sleep: Suspends for the full delay; injectable for tests.
    /// - Returns: Whether a reattach ended the wait or the delay elapsed.
    public static func waitForReattach(
        of deviceIdentifier: String?,
        upTo delay: Duration,
        deviceEvents: @escaping @Sendable () -> AsyncThrowingStream<DeviceEvent, Error>,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws -> ReattachWaitOutcome {
        try await withThrowingTaskGroup(of: ReattachWaitOutcome.self) { group in
            group.addTask {
                try await sleep(delay)
                return .waited
            }
            group.addTask {
                do {
                    for try await event in deviceEvents() {
                        guard case .attached(let device) = event else {
                            continue
                        }
                        if deviceIdentifier == nil
                            || device.identifier == deviceIdentifier {
                            return .reattached
                        }
                    }
                } catch {
                    // Fall through to waiting: losing the watch stream must
                    // not fail or shorten the retry schedule.
                }
                // No matching attach arrived before the stream ended. Park
                // until the sleeping sibling finishes so the group's first
                // result is the elapsed delay, not this early stream end.
                try await Task.sleep(for: .seconds(86_400))
                return .waited
            }
            defer {
                group.cancelAll()
            }
            guard let outcome = try await group.next() else {
                return .waited
            }
            return outcome
        }
    }
}

/// Minimal thread-safe latch marking that a cycle reported readiness.
private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
