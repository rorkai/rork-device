import Foundation
import XCTest
@testable import RorkDevice

final class DeviceClientIntegrationTests: XCTestCase {
    func testInstallsApplicationThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))
        let ipaURL = try temporaryFile(contents: Data("fake ipa".utf8))
        defer { try? FileManager.default.removeItem(at: ipaURL) }
        var progress: [InstallationProgress] = []

        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.session(for: device, pairingRecord: try testPairingRecord())
        try await session.installApplication(
            ipaURL: ipaURL,
            bundleIdentifier: "com.example.app"
        ) {
            progress.append($0)
        }

        XCTAssertEqual(progress.map(\.status), ["Installing", "Complete"])
        XCTAssertEqual(daemon.connectedPorts, [62078, 1234, 2345])
        XCTAssertEqual(daemon.afcOperations, [9, 8, 13, 16, 20])
        XCTAssertEqual(daemon.installedPackagePaths, ["/PublicStaging/com.example.app.ipa"])
    }

    func testInstallsInMemoryApplicationThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))
        var progress: [InstallationProgress] = []

        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.session(for: device, pairingRecord: try testPairingRecord())
        try await session.installApplication(
            ipaData: Data("fake ipa".utf8),
            bundleIdentifier: "com.example.memory"
        ) {
            progress.append($0)
        }

        XCTAssertEqual(progress.map(\.status), ["Installing", "Complete"])
        XCTAssertEqual(daemon.connectedPorts, [62078, 1234, 2345])
        XCTAssertEqual(daemon.afcOperations, [9, 8, 13, 16, 20])
        XCTAssertEqual(daemon.installedPackagePaths, ["/PublicStaging/com.example.memory.ipa"])
    }

    func testManagesProvisioningProfilesThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.session(for: device, pairingRecord: try testPairingRecord())

        try await session.installProvisioningProfile(Data([1, 2, 3]))
        let profiles = try await session.copyProvisioningProfiles()
        try await session.removeProvisioningProfile(identifier: "profile-uuid")

        XCTAssertEqual(profiles, [Data([9, 9, 9])])
        XCTAssertEqual(daemon.connectedPorts, [62078, 3456, 3456, 3456])
        XCTAssertEqual(daemon.misagentMessageTypes, ["Install", "CopyAll", "Remove"])
    }

    func testSecureSessionUpgraderIsUsedForLockdownAndSecureServices() async throws {
        let daemon = try FakeUSBMuxDaemon(
            secureLockdown: true,
            secureServices: [LockdownServiceName.afc.rawValue]
        )
        defer { daemon.stop() }
        let upgrader = RecordingSecureSessionUpgrader()
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port),
            secureSessionUpgrader: upgrader
        )
        let ipaURL = try temporaryFile(contents: Data("fake ipa".utf8))
        defer { try? FileManager.default.removeItem(at: ipaURL) }

        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.session(for: device, pairingRecord: try testPairingRecord())
        XCTAssertEqual(upgrader.upgradeCount, 1)

        _ = try await session.stageApplication(ipaURL: ipaURL, bundleIdentifier: "com.example.app")

        XCTAssertEqual(upgrader.upgradeCount, 2)
        XCTAssertEqual(daemon.connectedPorts, [62078, 1234])
    }
}

private final class RecordingSecureSessionUpgrader: SecureSessionUpgrader {
    private let queue = DispatchQueue(label: "dev.rork.rork-device.tests.secure-upgrader")
    private var _upgradeCount = 0

    var upgradeCount: Int {
        queue.sync { _upgradeCount }
    }

    func upgrade(_ connection: DeviceConnection, pairingRecord: PairingRecord) async throws -> DeviceConnection {
        queue.sync {
            _upgradeCount += 1
        }
        return connection
    }
}

private func testPairingRecord() throws -> PairingRecord {
    try PairingRecord.parse(
        PropertyListSerialization.data(
            fromPropertyList: [
                "UDID": "fake-device-1",
                "HostID": "host-1",
                "SystemBUID": "system-1",
            ],
            format: .xml,
            options: 0
        )
    )
}

private func temporaryFile(contents: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try contents.write(to: url)
    return url
}
