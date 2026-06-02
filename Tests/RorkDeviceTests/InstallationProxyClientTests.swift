import Foundation
import XCTest
@testable import RorkDevice

final class InstallationProxyClientTests: XCTestCase {
    func testApplicationsReturnTypedCurrentList() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "CurrentList": [
                [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleDisplayName": "Example App",
                    "CFBundleName": "Example",
                ],
            ],
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        let apps = try await client.applications(matching: .user)

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(apps.first?.displayName, "Example App")

        let request = try XCTUnwrap(decodedProxyMessage(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "Browse")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "User")
    }

    func testRawApplicationsReturnCurrentList() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "CurrentList": [
                [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleName": "Example",
                ],
            ],
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        let apps = try await client.rawApplications(matching: .user)

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?["CFBundleIdentifier"] as? String, "com.example.app")
    }

    func testApplicationsReturnEmptyListWhenCurrentAmountIsZero() async throws {
        let inbound = try PropertyListMessageFramer.encode(["CurrentAmount": 0])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        let apps = try await client.applications(matching: .all)

        XCTAssertEqual(apps.count, 0)
    }

    func testApplicationsRejectMalformedResponse() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": "Complete"])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.applications(matching: .user) }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("InstallationProxy Browse response did not include CurrentList.")
            )
        }
    }

    func testInstallEmitsProgressUntilComplete() async throws {
        var inbound = Data()
        inbound.append(try PropertyListMessageFramer.encode([
            "Status": "Installing",
            "PercentComplete": 50,
        ]))
        inbound.append(try PropertyListMessageFramer.encode([
            "Status": "Complete",
        ]))
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)
        let events = EventRecorder<InstallationProgress>()

        try await client.install(packagePath: "/PublicStaging/App.ipa", bundleIdentifier: "app.example") {
            events.append($0)
        }

        XCTAssertEqual(events.values.map(\.status), [.installing, .complete])
        XCTAssertEqual(events.values.first?.percentComplete, 50)
    }

    func testInstallPreservesUnknownProgressStatus() async throws {
        var inbound = Data()
        inbound.append(try PropertyListMessageFramer.encode([
            "Status": "PreparingSomethingNew",
        ]))
        inbound.append(try PropertyListMessageFramer.encode([
            "Status": "Complete",
        ]))
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)
        let events = EventRecorder<InstallationProgress>()

        try await client.install(packagePath: "/PublicStaging/App.ipa") {
            events.append($0)
        }

        XCTAssertEqual(events.values.first?.status, InstallationStatus(rawValue: "PreparingSomethingNew"))
        XCTAssertEqual(events.values.first?.status.rawValue, "PreparingSomethingNew")
    }

    func testInstallThrowsDeviceError() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Status": "Failed",
            "Error": "ApplicationVerificationFailed",
            "ErrorDescription": "Signature rejected",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        do {
            try await client.install(packagePath: "/PublicStaging/App.ipa")
            XCTFail("Expected install to throw.")
        } catch let error as RorkDeviceError {
            XCTAssertEqual(
                error,
                .installationProxy(InstallationError(code: .applicationVerificationFailed, message: "Signature rejected"))
            )
        }
    }

    func testInstallPreservesUnknownErrorCode() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Status": "Failed",
            "Error": "SomethingNewFailed",
            "ErrorDescription": "The device reported a new error.",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        do {
            try await client.install(packagePath: "/PublicStaging/App.ipa")
            XCTFail("Expected install to throw.")
        } catch let error as RorkDeviceError {
            XCTAssertEqual(
                error,
                .installationProxy(InstallationError(
                    code: "SomethingNewFailed",
                    message: "The device reported a new error."
                ))
            )
        }
    }

    func testInstallThrowsWhenConnectionEndsBeforeComplete() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Status": "Installing",
            "PercentComplete": 10,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.install(packagePath: "/PublicStaging/App.ipa") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .transport("Fake connection underflow."))
        }
    }

    func testUninstallSendsBundleIdentifierAndProgress() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": "Complete"])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)
        let events = EventRecorder<InstallationProgress>()

        try await client.uninstall(bundleIdentifier: "com.example.app") {
            events.append($0)
        }

        XCTAssertEqual(events.values.map(\.status), [.complete])
        let request = try XCTUnwrap(decodedProxyMessage(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "Uninstall")
        XCTAssertEqual(request["ApplicationIdentifier"] as? String, "com.example.app")
    }
}

private func decodedProxyMessage(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}
