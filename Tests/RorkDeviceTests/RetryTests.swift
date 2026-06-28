import Foundation
import XCTest
@testable import RorkDevice

final class RetryTests: XCTestCase {
    // MARK: - Backoff schedules

    func testConstantBackoffWaitsTheSameDelayBeforeEachRetry() {
        let backoff = Backoff.constant(.milliseconds(200), maxAttempts: 3)

        XCTAssertEqual(backoff.maxAttempts, 3)
        XCTAssertEqual(backoff.delay(beforeAttempt: 0), .zero)
        XCTAssertEqual(backoff.delay(beforeAttempt: 1), .milliseconds(200))
        XCTAssertEqual(backoff.delay(beforeAttempt: 2), .milliseconds(200))
    }

    func testExponentialBackoffDoublesAndCapsAtMaximum() {
        let backoff = Backoff.exponential(
            initial: .milliseconds(500),
            factor: 2,
            maximum: .seconds(8),
            maxAttempts: 6
        )

        XCTAssertEqual(backoff.maxAttempts, 6)
        XCTAssertEqual(backoff.delay(beforeAttempt: 0), .zero)
        XCTAssertEqual(backoff.delay(beforeAttempt: 1), .milliseconds(500))
        XCTAssertEqual(backoff.delay(beforeAttempt: 2), .seconds(1))
        XCTAssertEqual(backoff.delay(beforeAttempt: 3), .seconds(2))
        XCTAssertEqual(backoff.delay(beforeAttempt: 4), .seconds(4))
        XCTAssertEqual(backoff.delay(beforeAttempt: 5), .seconds(8))
        // Stays capped past the nominal attempt budget without overflowing.
        XCTAssertEqual(backoff.delay(beforeAttempt: 40), .seconds(8))
    }

    func testDelaysBackoffUsesTheExplicitSchedule() {
        let backoff = Backoff.delays([.zero, .milliseconds(25), .seconds(1)])

        XCTAssertEqual(backoff.maxAttempts, 3)
        XCTAssertEqual(backoff.delay(beforeAttempt: 0), .zero)
        XCTAssertEqual(backoff.delay(beforeAttempt: 1), .milliseconds(25))
        XCTAssertEqual(backoff.delay(beforeAttempt: 2), .seconds(1))
    }

    // MARK: - retry

    func testRetrySucceedsOnTheFirstAttemptWithoutSleeping() async throws {
        let sleeps = DurationRecorder()
        let attempts = CountRecorder()

        let value = try await retry(
            .constant(.seconds(1), maxAttempts: 3),
            sleep: { await sleeps.record($0) },
            isRetryable: { _ in true }
        ) {
            attempts.increment()
            return "ok"
        }

        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts.count, 1)
        let recorded = await sleeps.values
        XCTAssertEqual(recorded, [])
    }

    func testRetryRetriesARetryableFailureThenSucceeds() async throws {
        let sleeps = DurationRecorder()
        let attempts = CountRecorder()

        let value = try await retry(
            .delays([.zero, .milliseconds(25), .milliseconds(50)]),
            sleep: { await sleeps.record($0) },
            isRetryable: { _ in true }
        ) {
            let attempt = attempts.increment()
            if attempt < 3 {
                throw RorkDeviceError.transport("transient")
            }
            return attempt
        }

        XCTAssertEqual(value, 3)
        XCTAssertEqual(attempts.count, 3)
        let recorded = await sleeps.values
        XCTAssertEqual(recorded, [.milliseconds(25), .milliseconds(50)])
    }

    func testRetryStopsOnANonRetryableFailure() async {
        let sleeps = DurationRecorder()
        let attempts = CountRecorder()
        let fatal = RorkDeviceError.protocolViolation("fatal")

        do {
            _ = try await retry(
                .delays([.zero, .milliseconds(25)]),
                sleep: { await sleeps.record($0) },
                isRetryable: { _ in false }
            ) {
                attempts.increment()
                throw fatal
            }
            XCTFail("Expected the non-retryable failure to propagate.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, fatal)
        }

        XCTAssertEqual(attempts.count, 1)
        let recorded = await sleeps.values
        XCTAssertEqual(recorded, [])
    }

    func testRetryThrowsTheFinalErrorAndReportsEachRetry() async {
        let attempts = CountRecorder()
        let retried = CountRecorder()
        let retryable = RorkDeviceError.transport("transient")

        do {
            _ = try await retry(
                .delays([.zero, .zero, .zero]),
                sleep: { _ in },
                isRetryable: { _ in true },
                onRetry: { _ in retried.increment() }
            ) {
                attempts.increment()
                throw retryable
            }
            XCTFail("Expected the final error to propagate.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, retryable)
        }

        XCTAssertEqual(attempts.count, 3)
        // onRetry fires only between attempts, never after the final failure.
        XCTAssertEqual(retried.count, 2)
    }
}

/// Records injected delays without introducing wall-clock waits.
private actor DurationRecorder {
    private var recorded: [Duration] = []
    var values: [Duration] { recorded }
    func record(_ duration: Duration) { recorded.append(duration) }
}

/// Counts operations without data races across closure captures.
private final class CountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
