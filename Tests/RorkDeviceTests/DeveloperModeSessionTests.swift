import Foundation
import XCTest

@testable import RorkDevice

final class DeveloperModeSessionTests: XCTestCase {
    func testReadsDeveloperModeStatusFromLockdownBackend() async throws {
        let backend = DeveloperModeSessionTestBackend(
            connection: FakeConnection(),
            developerModeEnabled: true
        )
        let session = DeviceSession(backend: backend)

        let enabled = try await session.isDeveloperModeEnabled()

        XCTAssertTrue(enabled)
        XCTAssertEqual(backend.developerModeStatusRequestCount, 1)
    }

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

    /// Deterministic Developer Mode state returned to the session.
    private let developerModeEnabled: Bool

    /// Service names requested through the Lockdown-compatible route.
    private(set) var startedServiceNames: [String] = []

    /// Number of Developer Mode status requests made through this backend.
    private(set) var developerModeStatusRequestCount = 0

    /// Creates a backend with one deterministic service connection.
    init(
        connection: DeviceConnection,
        developerModeEnabled: Bool = false
    ) {
        self.connection = connection
        self.developerModeEnabled = developerModeEnabled
    }

    /// Returns minimal information required by the backend protocol.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Returns the configured status and records the query.
    func isDeveloperModeEnabled() async throws -> Bool {
        developerModeStatusRequestCount += 1
        return developerModeEnabled
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
