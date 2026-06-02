import XCTest
@testable import RorkDeviceCLI

final class RorkDeviceCLITests: XCTestCase {
    func testHelpMentionsCoreCommands() {
        let help = RorkDeviceCommand.helpMessage()

        XCTAssertTrue(help.contains("rorkdevice"))
        XCTAssertTrue(help.contains("list"))
        XCTAssertTrue(help.contains("install"))
        XCTAssertTrue(help.contains("profiles"))
    }

    func testInstallCommandParsesArguments() throws {
        let command = try Install.parse([
            "--pairing-record", "pairing.plist",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.ipaPath, "App.ipa")
        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
    }

    func testAppsListCommandParsesApplicationType() throws {
        let command = try AppsList.parse([
            "--pairing-record", "pairing.plist",
            "--type", "Any",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.type, .any)
    }

    func testInfoCommandParsesDirectEndpoint() throws {
        let command = try Info.parse([
            "--host", "127.0.0.1",
            "--port", "62079",
            "--pairing-record", "pairing.plist",
        ])

        XCTAssertEqual(command.connection.host, "127.0.0.1")
        XCTAssertEqual(command.connection.port, 62079)
        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
    }

    func testProfilesCopyCommandParsesOutputDirectoryAndLegacyMode() throws {
        let command = try ProfilesCopy.parse([
            "--pairing-record", "pairing.plist",
            "--output-directory", "Profiles",
            "--legacy",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.outputDirectory, "Profiles")
        XCTAssertTrue(command.legacy)
    }

    func testProfilesRemoveCommandParsesIdentifier() throws {
        let command = try ProfilesRemove.parse([
            "--pairing-record", "pairing.plist",
            "profile-uuid",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.identifier, "profile-uuid")
    }
}
