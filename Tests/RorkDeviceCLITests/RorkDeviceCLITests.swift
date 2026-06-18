import RorkDevice
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
        XCTAssertTrue(help.contains("launch"))
        XCTAssertTrue(help.contains("terminate"))
        XCTAssertTrue(help.contains("profiles"))
        XCTAssertTrue(help.contains("pairing"))
        XCTAssertTrue(help.contains("developer-mode"))
        XCTAssertTrue(help.contains("remote-pairing"))
        XCTAssertTrue(help.contains("tunnel"))
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

    func testListCommandParsesUSBFilter() throws {
        let command = try List.parse(["--usb", "--json"])

        XCTAssertTrue(command.usb)
        XCTAssertTrue(command.json)
    }

    func testUSBFilterAcceptsOnlyUSBDevices() {
        let usbDevice = Device(
            identifier: "usb-device",
            connection: .usbmux(deviceID: 1),
            properties: ["ConnectionType": "USB"]
        )
        let networkDevice = Device(
            identifier: "network-device",
            connection: .usbmux(deviceID: 2),
            properties: ["ConnectionType": "Network"]
        )

        XCTAssertTrue(isUSBDevice(usbDevice))
        XCTAssertFalse(isUSBDevice(networkDevice))
    }

    func testDeviceListJSONEncodesIdentifiers() throws {
        let data = try deviceListJSON([
            Device(
                identifier: "device-1",
                connection: .usbmux(deviceID: 1)
            ),
            Device(
                identifier: "device-2",
                connection: .usbmux(deviceID: 2)
            ),
        ])

        let identifiers = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String]
        )

        XCTAssertEqual(identifiers, ["device-1", "device-2"])
    }

    func testInstallCommandParsesUserspaceRemoteServiceRoute() throws {
        let command = try Install.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ])

        XCTAssertEqual(
            command.connection.userspaceDeviceAddress,
            "fd92:fbe0:acf3::2"
        )
        XCTAssertEqual(
            command.connection.userspaceGatewayHost,
            "127.0.0.1"
        )
        XCTAssertEqual(
            command.connection.userspaceGatewayPort,
            60_112
        )
        XCTAssertEqual(
            command.connection.remoteServiceDiscoveryPort,
            54_130
        )
    }

    func testInstallCommandRejectsIncompleteUserspaceRoute() {
        XCTAssertThrowsError(try Install.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ]))
    }

    func testInstallCommandRejectsBlankUserspaceDeviceAddress() {
        XCTAssertThrowsError(try Install.parse([
            "--userspace-device-address", " \n ",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ]))
    }

    func testLaunchCommandParsesProcessOptions() throws {
        let command = try Launch.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "--kill-existing",
            "--arg=--diagnostic",
            "--env=RORK_MODE=test",
            "com.example.app",
        ])

        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
        XCTAssertTrue(command.killExisting)
        XCTAssertEqual(command.arguments, ["--diagnostic"])
        XCTAssertEqual(command.environment, ["RORK_MODE=test"])
    }

    func testLaunchCommandRequiresAUserspaceRoute() {
        XCTAssertThrowsError(try Launch.parse([
            "--pairing-record", "pairing.plist",
            "com.example.app",
        ]))
    }

    func testTerminateCommandParsesBundleIdentifier() throws {
        let command = try Terminate.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "com.example.app",
        ])

        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
    }

    func testTerminateCommandRequiresAUserspaceRoute() {
        XCTAssertThrowsError(try Terminate.parse([
            "--pairing-record", "pairing.plist",
            "com.example.app",
        ]))
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
            "--json",
        ])

        XCTAssertEqual(command.connection.host, "127.0.0.1")
        XCTAssertEqual(command.connection.port, 62079)
        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertTrue(command.json)
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

    func testLockdownInfoJSONPreservesScalarLockdownKeys() throws {
        let info = DeviceInfo(values: [
            "UniqueDeviceID": "device-1",
            "DeviceClass": "iPhone",
            "ProductVersion": "26.5.1",
        ])

        let data = try lockdownInfoJSON(info)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(values["UniqueDeviceID"], "device-1")
        XCTAssertEqual(values["DeviceClass"], "iPhone")
        XCTAssertEqual(values["ProductVersion"], "26.5.1")
    }

    func testPairingValidateCommandParsesDeviceIdentifier() throws {
        let command = try PairingValidate.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
    }

    func testPairingEnableWirelessCommandParsesDeviceIdentifier() throws {
        let command = try PairingEnableWireless.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
    }

    func testPairingValidationRejectsUnexpectedDeviceIdentifier() {
        let info = DeviceInfo(values: [
            "UniqueDeviceID": "device-2",
        ])

        XCTAssertThrowsError(
            try validatePairingIdentity(
                info,
                expectedDeviceIdentifier: "device-1"
            )
        )
    }

    func testPairingValidationRequiresDeviceIdentifierFromLockdown() {
        let info = DeviceInfo(values: [:])

        XCTAssertThrowsError(
            try validatePairingIdentity(
                info,
                expectedDeviceIdentifier: "device-1"
            )
        )
    }

    func testDeveloperModeRevealCommandParsesDeviceIdentifier() throws {
        let command = try DeveloperModeReveal.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
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

    func testRemotePairingTrustCommandParsesUserspaceTunnel() throws {
        let command = try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", "fd92:fbe0:acf3::2",
            "--discovery-port", "54130",
            "--gateway-port", "60112",
        ])

        XCTAssertEqual(command.identityPath, "selfIdentity.plist")
        XCTAssertEqual(command.deviceAddress, "fd92:fbe0:acf3::2")
        XCTAssertEqual(command.discoveryPort, 54_130)
        XCTAssertEqual(command.gatewayHost, "127.0.0.1")
        XCTAssertEqual(command.gatewayPort, 60_112)
    }

    func testRemotePairingTrustCommandRejectsBlankDeviceAddress() {
        XCTAssertThrowsError(try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", " \n ",
            "--discovery-port", "54130",
            "--gateway-port", "60112",
        ]))
    }

    func testRemotePairingTrustCommandRejectsBlankGatewayHost() {
        XCTAssertThrowsError(try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", "fd92:fbe0:acf3::2",
            "--discovery-port", "54130",
            "--gateway-host", " \n ",
            "--gateway-port", "60112",
        ]))
    }

    func testTunnelStartCommandParsesGatewayConfiguration() throws {
        let command = try TunnelStartCommand.parse([
            "--udid", "device-1",
            "--identity", "selfIdentity.plist",
            "--gateway-port", "60112",
            "--mtu", "1500",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
        XCTAssertEqual(command.identityPath, "selfIdentity.plist")
        XCTAssertEqual(command.gatewayHost, "127.0.0.1")
        XCTAssertEqual(command.gatewayPort, 60_112)
        XCTAssertEqual(command.maximumTransmissionUnit, 1_500)
    }

    func testTunnelStartCommandRejectsAnExistingUserspaceRoute() {
        XCTAssertThrowsError(try TunnelStartCommand.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "--identity", "selfIdentity.plist",
        ]))
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

    func testFilesRejectsContainerWithoutBundleIdentifier() {
        XCTAssertThrowsError(try FilesList.parse([
            "--pairing-record", "pairing.plist",
            "--container",
            "/Documents",
        ]))
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
