import Foundation
import XCTest

@testable import RorkDevice

final class DeveloperModeSessionTests: XCTestCase {
    func testRevealDeveloperModeUsesAMFILockdownService() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "success": true
            ])
        )
        let backend = DeveloperModeSessionTestBackend(
            connection: connection
        )
        let session = DeviceSession(backend: backend)

        try await session.revealDeveloperMode()

        XCTAssertEqual(
            backend.startedServiceNames,
            ["com.apple.amfi.lockdown"]
        )
        XCTAssertTrue(connection.isClosed)
    }

    func testRevealDeveloperModeClosesServiceAfterFailure() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": "DeviceLocked"
            ])
        )
        let backend = DeveloperModeSessionTestBackend(
            connection: connection
        )
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync(
            {
                try await session.revealDeveloperMode()
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .lockdown(
                        "Developer Mode reveal failed: DeviceLocked"
                    )
                )
            }
        )

        XCTAssertTrue(connection.isClosed)
    }
}

/// Device-session backend that records the service requested by the operation.
private final class DeveloperModeSessionTestBackend: DeviceSessionBackend {
    /// Connection returned when the session opens the AMFI service.
    private let connection: DeviceConnection

    /// Service names requested through the Lockdown-compatible route.
    private(set) var startedServiceNames: [String] = []

    /// Creates a backend with one deterministic service connection.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Returns minimal information required by the backend protocol.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Records and returns the configured service connection.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedServiceNames.append(serviceName)
        return connection
    }
}
