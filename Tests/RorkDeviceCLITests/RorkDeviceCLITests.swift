import XCTest
@testable import RorkDeviceCLI

final class RorkDeviceCLITests: XCTestCase {
    func testHelpMentionsCoreCommands() {
        let help = RorkDeviceCommand.helpMessage()

        XCTAssertTrue(help.contains("rorkdevice"))
        XCTAssertTrue(help.contains("list"))
        XCTAssertTrue(help.contains("watch"))
        XCTAssertTrue(help.contains("files"))
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
            "--type", "all",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.type, .all)
    }

    func testAppsListCommandParsesProtocolApplicationType() throws {
        let command = try AppsList.parse([
            "--pairing-record", "pairing.plist",
            "--type", "Any",
        ])

        XCTAssertEqual(command.type, .all)
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

    func testInfoCommandRejectsHostAndUDIDTogether() {
        XCTAssertThrowsError(try Info.parse([
            "--host", "127.0.0.1",
            "--udid", "device-1",
            "--pairing-record", "pairing.plist",
        ]))
    }

    func testInfoCommandRejectsPortWithoutHost() {
        XCTAssertThrowsError(try Info.parse([
            "--port", "62079",
            "--pairing-record", "pairing.plist",
        ]))
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

    func testFilesListParsesHouseArrestOptions() throws {
        let command = try FilesList.parse([
            "--pairing-record", "pairing.plist",
            "--bundle-identifier", "com.example.app",
            "--container",
            "/Documents",
        ])

        XCTAssertEqual(command.access.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.access.bundleIdentifier, "com.example.app")
        XCTAssertTrue(command.access.container)
        XCTAssertEqual(command.path, "/Documents")
    }

    func testFilesPushParsesLocalAndRemotePaths() throws {
        let command = try FilesPush.parse([
            "--pairing-record", "pairing.plist",
            "local.txt",
            "/Documents/local.txt",
        ])

        XCTAssertEqual(command.access.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.localPath, "local.txt")
        XCTAssertEqual(command.remotePath, "/Documents/local.txt")
    }
}
