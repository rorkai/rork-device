import Foundation

/// A bounded, composable backoff schedule for retry loops.
///
/// A schedule describes both *how many* attempts to make (`maxAttempts`,
/// including the first immediate one) and *how long* to wait before each one.
/// The first attempt always runs immediately; `delay(beforeAttempt:)` returns
/// the wait that precedes a given 0-based attempt, so index `0` is always
/// `.zero`.
///
/// `Backoff` deliberately mirrors the shape of the Swift Async Algorithms
/// `retry`/`Backoff` pitch so this in-house utility can be swapped for the
/// standard one once it ships, without touching call sites' intent.
public struct Backoff: Sendable {
    /// Total number of attempts, including the first immediate attempt.
    public let maxAttempts: Int

    /// Computes the wait that precedes the attempt at a 0-based `index`.
    private let delayForAttempt: @Sendable (Int) -> Duration

    /// Creates a schedule from an explicit per-attempt delay function.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total attempts, clamped to at least one.
    ///   - delayForAttempt: Wait preceding the attempt at the given 0-based
    ///     index. Index `0` is always treated as `.zero` by
    ///     ``delay(beforeAttempt:)``, so this is only consulted for `index >= 1`.
    public init(
        maxAttempts: Int,
        delayForAttempt: @escaping @Sendable (Int) -> Duration
    ) {
        self.maxAttempts = max(maxAttempts, 1)
        self.delayForAttempt = delayForAttempt
    }

    /// Returns the wait that precedes the attempt at a 0-based `index`.
    ///
    /// The first attempt (`index <= 0`) is never delayed.
    public func delay(beforeAttempt index: Int) -> Duration {
        index <= 0 ? .zero : delayForAttempt(index)
    }

    /// A schedule that waits the same `delay` before every retry.
    public static func constant(_ delay: Duration, maxAttempts: Int) -> Backoff {
        Backoff(maxAttempts: maxAttempts) { _ in delay }
    }

    /// An exponential schedule capped at `maximum`.
    ///
    /// The first retry waits `initial`; each subsequent retry multiplies the
    /// previous wait by `factor`, never exceeding `maximum`. The exponent is
    /// clamped so the intermediate product cannot overflow before it is capped.
    public static func exponential(
        initial: Duration,
        factor: Double = 2,
        maximum: Duration,
        maxAttempts: Int
    ) -> Backoff {
        precondition(factor >= 1, "Exponential backoff requires a factor >= 1.")
        return Backoff(maxAttempts: maxAttempts) { index in
            // `index >= 1` here; index 0 is handled as `.zero` by the accessor.
            let exponent = Double(min(index - 1, 52))
            let scaled = initial * pow(factor, exponent)
            return min(scaled, maximum)
        }
    }

    /// A schedule from an explicit list of pre-attempt delays.
    ///
    /// `maxAttempts` equals the number of delays. Index `0` is treated as
    /// `.zero`. This is an escape hatch for irregular schedules and the seam
    /// used by deterministic tests.
    public static func delays(_ delays: [Duration]) -> Backoff {
        Backoff(maxAttempts: delays.count) { index in
            index < delays.count ? delays[index] : (delays.last ?? .zero)
        }
    }
}

/// Runs `operation` until it succeeds, the attempt budget is spent, or a thrown
/// error is rejected by `isRetryable`.
///
/// The first attempt runs immediately; each subsequent attempt is preceded by
/// the schedule's delay. When every attempt fails, the error from the final
/// attempt is propagated. `isRetryable` is the single place callers decide which
/// failures are transient, so the loop mechanics stay free of domain logic.
///
/// - Parameters:
///   - backoff: Attempt budget and per-attempt delays.
///   - sleep: Suspends for the requested delay; injectable for tests.
///   - isRetryable: Whether a thrown error should be retried.
///   - onRetry: Observes each error that will be retried, before the next wait.
///   - operation: The work to attempt.
public func retry<Success>(
    _ backoff: Backoff,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    isRetryable: (any Error) -> Bool,
    onRetry: (any Error) -> Void = { _ in },
    operation: () async throws -> Success
) async throws -> Success {
    var attempt = 0
    while true {
        let delay = backoff.delay(beforeAttempt: attempt)
        if delay > .zero {
            try await sleep(delay)
        }

        do {
            return try await operation()
        } catch {
            attempt += 1
            guard attempt < backoff.maxAttempts, isRetryable(error) else {
                throw error
            }
            onRetry(error)
        }
    }
}
