import Foundation
import XCTest

@testable import RorkDevice

/// The gate hands the current tunnel cycle's shared session to IPC handlers
/// and makes requests that arrive between cycles wait for the next ready.
final class TunnelAgentSessionGateTests: XCTestCase {
    func testHandsOutThePublishedSessionImmediately() async throws {
        let gate = TunnelAgentSessionGate()
        let session = DeviceSession(backend: IdleSessionBackend())
        gate.publish(session)

        let provided = try await gate.waitForSession(upTo: .seconds(1))

        XCTAssertTrue(provided === session)
    }

    func testWaitsForASessionPublishedLater() async throws {
        let gate = TunnelAgentSessionGate()
        let next = DeviceSession(backend: IdleSessionBackend())
        let waiting = Task {
            try await gate.waitForSession(upTo: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.publish(next)

        let provided = try await waiting.value

        XCTAssertTrue(provided === next)
    }

    func testKeepsWaitersPendingAcrossALossUntilTheNextCycle() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: IdleSessionBackend()))
        gate.markLost(reason: "stream reset")
        let replacement = DeviceSession(backend: IdleSessionBackend())
        let waiting = Task {
            try await gate.waitForSession(upTo: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.publish(replacement)

        let provided = try await waiting.value

        XCTAssertTrue(provided === replacement)
    }

    func testTimesOutWithTheLastLossReasonWhileTheTunnelIsDown() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: IdleSessionBackend()))
        gate.markLost(reason: "the cable was unplugged")

        do {
            _ = try await gate.waitForSession(upTo: .milliseconds(50))
            XCTFail("Expected the wait to time out")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("the cable was unplugged"),
                "Expected the last loss reason in \(error)"
            )
        }
    }

    func testANilLossReasonKeepsTheLastKnownReason() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: IdleSessionBackend()))
        gate.markLost(reason: "the cable was unplugged")
        gate.markLost(reason: nil)

        do {
            _ = try await gate.waitForSession(upTo: .milliseconds(50))
            XCTFail("Expected the wait to time out")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("the cable was unplugged"),
                "Expected the last loss reason in \(error)"
            )
        }
    }

    func testACancelledWaiterStopsWaitingPromptly() async throws {
        let gate = TunnelAgentSessionGate()
        let waiting = Task {
            try await gate.waitForSession(upTo: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(50))

        waiting.cancel()

        do {
            _ = try await waiting.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The waiter observed its own cancellation instead of the timeout.
        }
    }
}

/// Backend for sessions that only need identity, never device access.
private final class IdleSessionBackend: DeviceSessionBackend {
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        throw RorkDeviceError.transport(
            "The gate test backend opens no services."
        )
    }
}
