import Foundation
import XCTest

@testable import RorkDevice

final class WirelessConnectionsSessionTests: XCTestCase {
    func testEnablesWirelessConnectionsThroughSessionBackend() async throws {
        let backend = WirelessConnectionsSessionTestBackend()
        let session = DeviceSession(backend: backend)

        try await session.enableWirelessConnections()

        XCTAssertEqual(backend.enableWirelessConnectionsCallCount, 1)
    }
}

/// Device-session backend that records wireless Lockdown configuration.
private final class WirelessConnectionsSessionTestBackend:
    DeviceSessionBackend
{
    /// Number of requests forwarded by the high-level session.
    private(set) var enableWirelessConnectionsCallCount = 0

    /// Returns minimal information required by the backend protocol.
    func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Records one wireless Lockdown configuration request.
    func enableWirelessConnections() async throws(RorkDeviceError) {
        enableWirelessConnectionsCallCount += 1
    }

    /// Rejects unrelated service requests in this focused test backend.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws(RorkDeviceError) -> DeviceConnection {
        throw RorkDeviceError.protocolViolation(
            "Unexpected service request: \(serviceName)"
        )
    }
}
