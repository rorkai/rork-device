import Foundation
@testable import RorkDevice
import XCTest

final class CompanionDeviceSessionTests: XCTestCase {
    /// Uses a fresh service stream for each request because some iOS versions
    /// close CompanionProxy after one response.
    func testReadsPairedCompanionDeviceInformation() async throws {
        let registryConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-1"],
            ])
        )
        let nameConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "DeviceName": "My Watch",
                ],
            ])
        )
        let modelConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "ModelNumber": "Model-1",
                ],
            ])
        )
        let backend = CompanionDeviceSessionTestBackend(
            connections: [
                registryConnection,
                nameConnection,
                modelConnection,
            ]
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
            Array(
                repeating: CompanionProxyClient.serviceName,
                count: 3
            )
        )
        XCTAssertTrue(registryConnection.isClosed)
        XCTAssertTrue(nameConnection.isClosed)
        XCTAssertTrue(modelConnection.isClosed)
    }

    /// Avoids opening metadata services when the registry reports no devices.
    func testEmptyRegistryUsesOnlyOneServiceConnection() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": [String](),
            ])
        )
        let backend = CompanionDeviceSessionTestBackend(
            connections: [connection]
        )
        let session = DeviceSession(backend: backend)

        let devices = try await session.pairedCompanionDevices()

        XCTAssertEqual(devices, [])
        XCTAssertEqual(
            backend.startedServiceNames,
            [CompanionProxyClient.serviceName]
        )
        XCTAssertTrue(connection.isClosed)
    }

    /// Infers a custom string key without exposing its generic spelling.
    func testReadsCustomStringCompanionValue() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "VendorDisplayName": "Custom Watch",
                ],
            ])
        )
        let backend = CompanionDeviceSessionTestBackend(
            connections: [connection]
        )
        let session = DeviceSession(backend: backend)

        let value = try await session.companionValue(
            for: .string("VendorDisplayName"),
            on: "WATCH-1"
        )

        XCTAssertEqual(value, "Custom Watch")
        XCTAssertEqual(
            backend.startedServiceNames,
            [CompanionProxyClient.serviceName]
        )
        XCTAssertTrue(connection.isClosed)
    }

    /// Infers integer and Boolean values from their custom key factories.
    func testReadsCustomScalarCompanionValues() async throws {
        let capacityConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "BatteryCurrentCapacity": 75,
                ],
            ])
        )
        let chargingConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "BatteryIsCharging": true,
                ],
            ])
        )
        let backend = CompanionDeviceSessionTestBackend(
            connections: [
                capacityConnection,
                chargingConnection,
            ]
        )
        let session = DeviceSession(backend: backend)

        let capacity = try await session.companionValue(
            for: .integer("BatteryCurrentCapacity"),
            on: "WATCH-1"
        )
        let charging = try await session.companionValue(
            for: .boolean("BatteryIsCharging"),
            on: "WATCH-1"
        )

        XCTAssertEqual(capacity, 75)
        XCTAssertEqual(charging, true)
        XCTAssertEqual(
            backend.startedServiceNames,
            Array(
                repeating: CompanionProxyClient.serviceName,
                count: 2
            )
        )
        XCTAssertTrue(capacityConnection.isClosed)
        XCTAssertTrue(chargingConnection.isClosed)
    }

    /// Returns nil for an absent typed value and still closes its connection.
    func testCompanionValueReturnsNilWhenAbsent() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [:],
            ])
        )
        let session = DeviceSession(
            backend: CompanionDeviceSessionTestBackend(
                connections: [connection]
            )
        )

        let value: String? = try await session.companionValue(
            for: .deviceName,
            on: "WATCH-1"
        )

        XCTAssertNil(value)
        XCTAssertTrue(connection.isClosed)
    }

    /// Closes the scoped service connection when a typed lookup fails.
    func testCompanionValueClosesConnectionAfterFailure() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([:])
        )
        let session = DeviceSession(
            backend: CompanionDeviceSessionTestBackend(
                connections: [connection]
            )
        )

        await XCTAssertThrowsErrorAsync(
            {
                let _: String? = try await session.companionValue(
                    for: .deviceName,
                    on: "WATCH-1"
                )
            },
            { error in
                guard case RorkDeviceError.protocolViolation = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        )

        XCTAssertTrue(connection.isClosed)
    }

    /// Rejects an empty companion identifier before opening a service.
    func testCompanionValueRejectsEmptyIdentifierBeforeConnecting() async {
        let backend = CompanionDeviceSessionTestBackend(connections: [])
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync(
            {
                let _: String? = try await session.companionValue(
                    for: .deviceName,
                    on: ""
                )
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .invalidInput(
                        "Companion device identifier must not be empty."
                    )
                )
            }
        )

        XCTAssertEqual(backend.startedServiceNames, [])
    }

    /// Rejects an empty registry key before opening a service.
    func testCompanionValueRejectsEmptyKeyBeforeConnecting() async {
        let backend = CompanionDeviceSessionTestBackend(connections: [])
        let session = DeviceSession(backend: backend)
        let key = CompanionRegistryKey<String>("")

        await XCTAssertThrowsErrorAsync(
            {
                let _: String? = try await session.companionValue(
                    for: key,
                    on: "WATCH-1"
                )
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .invalidInput(
                        "Companion device registry key must not be empty."
                    )
                )
            }
        )

        XCTAssertEqual(backend.startedServiceNames, [])
    }

    /// Verifies that session-owned service connections close on protocol
    /// failures.
    func testClosesCompanionProxyAfterProtocolFailure() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([:])
        )
        let session = DeviceSession(
            backend: CompanionDeviceSessionTestBackend(
                connections: [connection]
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
    /// Connections returned in request order.
    private var connections: [DeviceConnection]

    /// Service names requested through the session.
    private(set) var startedServiceNames: [String] = []

    /// Creates a backend with deterministic one-request connections.
    init(connections: [DeviceConnection]) {
        self.connections = connections
    }

    /// Returns the minimal information required by the backend protocol.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Returns a disabled status because this backend does not model AMFI.
    func isDeveloperModeEnabled() async throws -> Bool {
        false
    }

    /// Records the requested service and returns the next connection.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedServiceNames.append(serviceName)
        guard !connections.isEmpty else {
            throw RorkDeviceError.transport(
                "No companion proxy test connection remains."
            )
        }
        return connections.removeFirst()
    }
}
