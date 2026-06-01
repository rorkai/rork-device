import Foundation
import XCTest
@testable import RorkDevice

final class InstallationProxyClientTests: XCTestCase {
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
}
