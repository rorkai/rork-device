import Foundation
import XCTest
@testable import RorkDevice

final class InstallationProxyClientTests: XCTestCase {
    func testBrowseReturnsCurrentList() async throws {
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

        let apps = try await client.browse(applicationType: .user)

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?["CFBundleIdentifier"] as? String, "com.example.app")

        let request = try XCTUnwrap(decodedProxyMessage(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "Browse")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "User")
    }

    func testBrowseReturnsEmptyListWhenCurrentAmountIsZero() async throws {
        let inbound = try PropertyListMessageFramer.encode(["CurrentAmount": 0])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        let apps = try await client.browse(applicationType: .any)

        XCTAssertEqual(apps.count, 0)
    }

    func testBrowseRejectsMalformedResponse() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": "Complete"])
        let connection = FakeConnection(inbound: inbound)
        let client = InstallationProxyClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.browse(applicationType: .user) }) { error in
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
        var events: [InstallationProgress] = []

        try await client.install(packagePath: "/PublicStaging/App.ipa", bundleIdentifier: "app.example") {
            events.append($0)
        }

        XCTAssertEqual(events.map(\.status), ["Installing", "Complete"])
        XCTAssertEqual(events.first?.percentComplete, 50)
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
            XCTAssertEqual(error, .installationProxy(name: "ApplicationVerificationFailed", description: "Signature rejected"))
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
        var events: [InstallationProgress] = []

        try await client.uninstall(bundleIdentifier: "com.example.app") {
            events.append($0)
        }

        XCTAssertEqual(events.map(\.status), ["Complete"])
        let request = try XCTUnwrap(decodedProxyMessage(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "Uninstall")
        XCTAssertEqual(request["ApplicationIdentifier"] as? String, "com.example.app")
    }
}

private func decodedProxyMessage(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}
