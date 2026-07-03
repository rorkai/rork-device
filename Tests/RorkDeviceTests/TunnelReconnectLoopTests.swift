import XCTest

@testable import RorkDevice

/// Behavior of the reconnect engine that keeps `tunnel start` alive when the
/// packet tunnel drops: retry scheduling, lifecycle events, and backoff reset.
final class TunnelReconnectLoopTests: XCTestCase {
    /// Backoff used by every test: 1s, then 2s, then 4s between attempts.
    private let backoff = Backoff.exponential(
        initial: .seconds(1),
        factor: 2,
        maximum: .seconds(60),
        maxAttempts: Int.max
    )

    func testStopsWithoutEventsWhenTheTunnelClosesCleanly() async throws {
        let recorder = ReconnectRecorder(cycles: [.serveThenClose])

        try await TunnelReconnectLoop.run(
            backoff: backoff,
            waitBeforeAttempt: recorder.wait,
            emit: recorder.emit,
            establishAndServe: recorder.establishAndServe
        )

        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.waits, [])
        XCTAssertEqual(recorder.cycleCount, 1)
    }

    func testRetriesEstablishmentFailuresWithGrowingBackoff() async throws {
        let recorder = ReconnectRecorder(cycles: [
            .failToEstablish("usbmux is empty"),
            .failToEstablish("still empty"),
            .serveThenClose,
        ])

        try await TunnelReconnectLoop.run(
            backoff: backoff,
            waitBeforeAttempt: recorder.wait,
            emit: recorder.emit,
            establishAndServe: recorder.establishAndServe
        )

        XCTAssertEqual(recorder.events, [
            .reEstablishing(attempt: 1, delay: .seconds(1), reason: "usbmux is empty"),
            .reEstablishing(attempt: 2, delay: .seconds(2), reason: "still empty"),
        ])
        XCTAssertEqual(recorder.waits, [.seconds(1), .seconds(2)])
        XCTAssertEqual(recorder.cycleCount, 3)
    }

    func testEmitsTunnelLostWhenAReadyTunnelDies() async throws {
        let recorder = ReconnectRecorder(cycles: [
            .serveThenLose("device unplugged"),
            .serveThenClose,
        ])

        try await TunnelReconnectLoop.run(
            backoff: backoff,
            waitBeforeAttempt: recorder.wait,
            emit: recorder.emit,
            establishAndServe: recorder.establishAndServe
        )

        XCTAssertEqual(recorder.events, [
            .tunnelLost(reason: "device unplugged"),
            .reEstablishing(attempt: 1, delay: .seconds(1), reason: "device unplugged"),
        ])
    }

    func testEstablishmentFailuresDoNotReportATunnelLoss() async throws {
        let recorder = ReconnectRecorder(cycles: [
            .failToEstablish("no device"),
            .serveThenClose,
        ])

        try await TunnelReconnectLoop.run(
            backoff: backoff,
            waitBeforeAttempt: recorder.wait,
            emit: recorder.emit,
            establishAndServe: recorder.establishAndServe
        )

        XCTAssertEqual(recorder.events, [
            .reEstablishing(attempt: 1, delay: .seconds(1), reason: "no device"),
        ])
    }

    func testBackoffRestartsAfterAHealthyCycle() async throws {
        let recorder = ReconnectRecorder(cycles: [
            .failToEstablish("first outage a"),
            .failToEstablish("first outage b"),
            .serveThenLose("healthy tunnel died"),
            .failToEstablish("second outage a"),
            .serveThenClose,
        ])

        try await TunnelReconnectLoop.run(
            backoff: backoff,
            waitBeforeAttempt: recorder.wait,
            emit: recorder.emit,
            establishAndServe: recorder.establishAndServe
        )

        XCTAssertEqual(recorder.waits, [
            .seconds(1),
            .seconds(2),
            .seconds(1),
            .seconds(2),
        ])
        XCTAssertEqual(recorder.events, [
            .reEstablishing(attempt: 1, delay: .seconds(1), reason: "first outage a"),
            .reEstablishing(attempt: 2, delay: .seconds(2), reason: "first outage b"),
            .tunnelLost(reason: "healthy tunnel died"),
            .reEstablishing(attempt: 1, delay: .seconds(1), reason: "healthy tunnel died"),
            .reEstablishing(attempt: 2, delay: .seconds(2), reason: "second outage a"),
        ])
    }

    func testWaitFailuresStopTheLoop() async {
        let recorder = ReconnectRecorder(
            cycles: [.failToEstablish("no device")],
            waitError: CancellationError()
        )

        do {
            try await TunnelReconnectLoop.run(
                backoff: backoff,
                waitBeforeAttempt: recorder.wait,
                emit: recorder.emit,
                establishAndServe: recorder.establishAndServe
            )
            XCTFail("Expected the wait failure to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.cycleCount, 1)
    }
}

/// Deterministic reattach-wait behavior: which race participant may end the
/// wait, and which events are ignored.
final class TunnelReconnectReattachWaitTests: XCTestCase {
    /// A sleep that never finishes, so only a device event can end the wait.
    private static let sleepForever: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3_600))
    }

    func testReattachOfTheWatchedDeviceEndsTheWaitEarly() async throws {
        let outcome = try await TunnelReconnectLoop.waitForReattach(
            of: "udid-1",
            upTo: .seconds(60),
            deviceEvents: {
                deviceEventStream([
                    .detached(identifier: "udid-1", connection: nil),
                    .attached(usbDevice(identifier: "udid-1")),
                ])
            },
            sleep: Self.sleepForever
        )

        XCTAssertEqual(outcome, .reattached)
    }

    func testAnyAttachEndsTheWaitWhenNoDeviceIsPinned() async throws {
        let outcome = try await TunnelReconnectLoop.waitForReattach(
            of: nil,
            upTo: .seconds(60),
            deviceEvents: {
                deviceEventStream([.attached(usbDevice(identifier: "whatever"))])
            },
            sleep: Self.sleepForever
        )

        XCTAssertEqual(outcome, .reattached)
    }

    func testOtherDevicesAndDetachEventsDoNotEndTheWait() async throws {
        let outcome = try await TunnelReconnectLoop.waitForReattach(
            of: "udid-1",
            upTo: .seconds(1),
            deviceEvents: {
                deviceEventStream([
                    .attached(usbDevice(identifier: "udid-2")),
                    .detached(identifier: "udid-1", connection: nil),
                ])
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .waited)
    }

    func testEventStreamFailureFallsBackToTheFullDelay() async throws {
        let sleepFinished = expectation(description: "full delay elapsed")
        let outcome = try await TunnelReconnectLoop.waitForReattach(
            of: "udid-1",
            upTo: .seconds(1),
            deviceEvents: {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: RorkDeviceError.transport("usbmuxd is down")
                    )
                }
            },
            sleep: { _ in sleepFinished.fulfill() }
        )

        await fulfillment(of: [sleepFinished], timeout: 1)
        XCTAssertEqual(outcome, .waited)
    }
}

/// Scripted double for the reconnect loop's establish/serve dependency.
///
/// Each scripted cycle either fails before readiness, reports readiness and
/// then loses the tunnel, or reports readiness and closes cleanly. Events and
/// waits are recorded in call order for assertions.
private final class ReconnectRecorder: @unchecked Sendable {
    enum Cycle {
        case failToEstablish(String)
        case serveThenLose(String)
        case serveThenClose
    }

    private let cycles: [Cycle]
    private let waitError: Error?
    private(set) var events: [TunnelReconnectLoop.Event] = []
    private(set) var waits: [Duration] = []
    private(set) var cycleCount = 0

    init(cycles: [Cycle], waitError: Error? = nil) {
        self.cycles = cycles
        self.waitError = waitError
    }

    func emit(_ event: TunnelReconnectLoop.Event) {
        events.append(event)
    }

    func wait(_ delay: Duration) async throws {
        waits.append(delay)
        if let waitError {
            throw waitError
        }
    }

    func establishAndServe(_ onReady: () -> Void) async throws {
        let cycle = cycles[cycleCount]
        cycleCount += 1
        switch cycle {
        case .failToEstablish(let message):
            throw ReconnectTestFailure(message: message)
        case .serveThenLose(let message):
            onReady()
            throw ReconnectTestFailure(message: message)
        case .serveThenClose:
            onReady()
        }
    }
}

/// Failure whose rendered description is exactly its message, pinning the
/// loop's `String(describing:)` reason contract without error-type prefixes.
private struct ReconnectTestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

/// Builds a finished event stream that replays the given events in order.
private func deviceEventStream(
    _ events: [DeviceEvent]
) -> AsyncThrowingStream<DeviceEvent, Error> {
    AsyncThrowingStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

/// Minimal usbmux-visible device fixture for reattach matching.
private func usbDevice(identifier: String) -> Device {
    Device(
        identifier: identifier,
        connection: .usbmux(deviceID: 1)
    )
}
