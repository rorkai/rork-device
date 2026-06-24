import Foundation
import XCTest
@testable import RorkDevice

final class RemoteServiceSessionTests: XCTestCase {
    func testStartsDirectRemoteXPCServiceWithoutShimCheckIn() async throws {
        let connection = FakeConnection()
        let connections = RemoteServiceConnectionRecorder(
            connection: connection
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: RemoteServiceDirectory(
                deviceIdentifier: "device-1",
                services: [
                    "com.apple.coredevice.appservice": 51_000,
                ]
            ),
            label: "RorkAppInstaller",
            openConnection: connections.connect
        )

        let openedConnection = try await backend.startRemoteService(
            named: "com.apple.coredevice.appservice"
        )

        XCTAssertTrue(openedConnection === connection)
        XCTAssertEqual(connections.endpoints, [
            RemoteServiceEndpoint(host: "fd00::2", port: 51_000),
        ])
        XCTAssertTrue(connection.sent.isEmpty)
    }

    func testStartsShimServiceAfterRSDCheckin() async throws {
        let connection = FakeConnection(inbound: try checkinResponses())
        let connections = RemoteServiceConnectionRecorder(connection: connection)
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.afc.shim.remote": 51_001,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller",
            openConnection: connections.connect
        )
        let session = DeviceSession(backend: backend)

        let openedConnection = try await session.startService(.afc)
        let info = try await session.fetchDeviceInfo()

        XCTAssertTrue(openedConnection === connection)
        XCTAssertEqual(info.uniqueDeviceID, "device-1")
        XCTAssertEqual(connections.endpoints, [
            RemoteServiceEndpoint(host: "fd00::2", port: 51_001),
        ])
        XCTAssertEqual(connection.sent.count, 1)
        let request = try decodePropertyListFrame(connection.sent[0])
        XCTAssertEqual(request["Label"] as? String, "RorkAppInstaller")
        XCTAssertEqual(request["ProtocolVersion"] as? String, "2")
        XCTAssertEqual(request["Request"] as? String, "RSDCheckin")
    }

    func testListsApplicationsThroughShimWhenCoreDeviceAppServiceIsAbsent() async throws {
        var inbound = try checkinResponses()
        inbound.append(try PropertyListMessageFramer.encode([
            "CurrentAmount": 1,
            "CurrentIndex": 0,
            "CurrentList": [
                [
                    "ApplicationType": "User",
                    "CFBundleDisplayName": "Example Developer App",
                    "CFBundleIdentifier": "com.example.developer-app",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                ],
            ],
        ]))
        inbound.append(try PropertyListMessageFramer.encode([
            "Status": "Complete",
        ]))
        let connection = FakeConnection(inbound: inbound)
        let connections = RemoteServiceConnectionRecorder(connection: connection)
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: RemoteServiceDirectory(
                deviceIdentifier: "device-1",
                services: [
                    "com.apple.mobile.installation_proxy.shim.remote": 51_005,
                ]
            ),
            label: "RorkAppInstaller",
            openConnection: connections.connect
        )
        let session = DeviceSession(backend: backend)

        let applications = try await session.installedApplications(matching: .all)

        XCTAssertEqual(applications.map(\.bundleIdentifier), [
            "com.example.developer-app",
        ])
        XCTAssertEqual(applications.map(\.version), ["1.2.3"])
        XCTAssertEqual(applications.map(\.buildVersion), ["456"])
        XCTAssertEqual(connections.endpoints, [
            RemoteServiceEndpoint(host: "fd00::2", port: 51_005),
        ])
        XCTAssertEqual(connection.sent.count, 2)
        let request = try decodePropertyListFrame(connection.sent[1])
        XCTAssertEqual(request["Command"] as? String, "Browse")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertNil(options["ApplicationType"])
        XCTAssertEqual(options["ShowLaunchProhibitedApps"] as? Bool, true)
    }

    func testRejectsMissingRemoteService() async throws {
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.afc.shim.remote": 51_001,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller"
        ) { _, _ in
            XCTFail("Connection should not be attempted.")
            return FakeConnection()
        }

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(named: "com.apple.mobile.installation_proxy", escrowBag: nil)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote service directory does not advertise com.apple.mobile.installation_proxy.shim.remote."
                )
            )
        }
    }

    func testRejectsUnexpectedRSDCheckinResponse() async throws {
        let connection = FakeConnection(inbound: try checkinResponses(secondRequest: "Unexpected"))
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.afc.shim.remote": 51_001,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller"
        ) { _, _ in
            connection
        }

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(named: "com.apple.afc", escrowBag: nil)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote service com.apple.afc.shim.remote on [fd00::2]:51001 returned an invalid StartService response: RSD check-in expected StartService, received Unexpected."
                )
            )
        }
    }

    func testReportsWhenRemoteServiceClosesBeforeRSDCheckinResponse() async throws {
        let connection = FakeConnection()
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.mobile.heartbeat.shim.remote": 51_002,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller"
        ) { _, _ in
            connection
        }

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(named: "com.apple.mobile.heartbeat", escrowBag: nil)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport(
                    "Remote service com.apple.mobile.heartbeat.shim.remote on [fd00::2]:51002 closed while waiting for RSDCheckin: Transport error: Fake connection underflow."
                )
            )
        }
        XCTAssertTrue(connection.isClosed)
    }

    func testReportsWhenRemoteServiceClosesBeforeStartServiceResponse() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode(["Request": "RSDCheckin"])
        )
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.mobile.heartbeat.shim.remote": 51_003,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller"
        ) { _, _ in
            connection
        }

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(named: "com.apple.mobile.heartbeat", escrowBag: nil)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport(
                    "Remote service com.apple.mobile.heartbeat.shim.remote on [fd00::2]:51003 closed while waiting for StartService: Transport error: Fake connection underflow."
                )
            )
        }
        XCTAssertTrue(connection.isClosed)
    }

    func testRejectsStartServiceResponseContainingDeviceError() async throws {
        let connection = FakeConnection(
            inbound: try checkinResponses(startServiceError: "InvalidService")
        )
        let directory = RemoteServiceDirectory(
            deviceIdentifier: "device-1",
            services: [
                "com.apple.mobile.heartbeat.shim.remote": 51_004,
            ]
        )
        let backend = RemoteServiceSessionBackend(
            host: "fd00::2",
            directory: directory,
            label: "RorkAppInstaller"
        ) { _, _ in
            connection
        }

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(named: "com.apple.mobile.heartbeat", escrowBag: nil)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote service com.apple.mobile.heartbeat.shim.remote on [fd00::2]:51004 returned an invalid StartService response: RSD check-in StartService failed: InvalidService."
                )
            )
        }
        XCTAssertTrue(connection.isClosed)
    }
}

private struct RemoteServiceEndpoint: Equatable {
    let host: String
    let port: UInt16
}

private final class RemoteServiceConnectionRecorder {
    private let connection: DeviceConnection
    private(set) var endpoints: [RemoteServiceEndpoint] = []

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func connect(host: String, port: UInt16) async throws -> DeviceConnection {
        endpoints.append(RemoteServiceEndpoint(host: host, port: port))
        return connection
    }
}

private func checkinResponses(
    secondRequest: String = "StartService",
    startServiceError: String? = nil
) throws -> Data {
    var data = Data()
    data.append(try PropertyListMessageFramer.encode(["Request": "RSDCheckin"]))
    var startServiceResponse = ["Request": secondRequest]
    if let startServiceError {
        startServiceResponse["Error"] = startServiceError
    }
    data.append(try PropertyListMessageFramer.encode(startServiceResponse))
    return data
}

private func decodePropertyListFrame(_ data: Data) throws -> [String: Any] {
    let length = try Int(data.bigEndianInteger(at: 0, as: UInt32.self))
    return try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: data.dropFirst(4).prefix(length),
            options: [],
            format: nil
        ) as? [String: Any]
    )
}
