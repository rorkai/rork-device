import Foundation
@testable import RorkDevice
import XCTest

final class CompanionDeviceSessionTests: XCTestCase {
    /// Verifies that one ordered service stream supplies every device metadata
    /// lookup and closes after completion.
    func testReadsPairedCompanionDeviceInformation() async throws {
        var inbound = Data()
        inbound.append(
            try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-1"],
            ])
        )
        inbound.append(
            try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "DeviceName": "My Watch",
                ],
            ])
        )
        inbound.append(
            try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "ModelNumber": "Model-1",
                ],
            ])
        )
        let connection = FakeConnection(inbound: inbound)
        let backend = CompanionDeviceSessionTestBackend(
            connection: connection
        )
        let session = DeviceSession(backend: backend)

        let devices = try await session.pairedCompanionDevices()

        XCTAssertEqual(
            devices,
            [
                PairedCompanionDevice(
                    udid: "WATCH-1",
                    name: "My Watch",
                    modelNumber: "Model-1"
                ),
            ]
        )
        XCTAssertEqual(
            backend.startedServiceNames,
            [CompanionProxyClient.serviceName]
        )
        XCTAssertTrue(connection.isClosed)
    }

    /// Verifies that session-owned service connections close on protocol
    /// failures.
    func testClosesCompanionProxyAfterProtocolFailure() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([:])
        )
        let session = DeviceSession(
            backend: CompanionDeviceSessionTestBackend(
                connection: connection
            )
        )

        await XCTAssertThrowsErrorAsync(
            {
                _ = try await session.pairedCompanionDevices()
            },
            { error in
                guard case RorkDeviceError.protocolViolation = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        )

        XCTAssertTrue(connection.isClosed)
    }
}

/// Device-session backend that records companion proxy service requests.
private final class CompanionDeviceSessionTestBackend:
    DeviceSessionBackend
{
    /// Connection returned for the companion proxy service.
    private let connection: DeviceConnection

    /// Service names requested through the session.
    private(set) var startedServiceNames: [String] = []

    /// Creates a backend with one deterministic service connection.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Returns the minimal information required by the backend protocol.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Returns a disabled status because this backend does not model AMFI.
    func isDeveloperModeEnabled() async throws -> Bool {
        false
    }

    /// Records the requested service and returns the configured connection.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedServiceNames.append(serviceName)
        return connection
    }
}
