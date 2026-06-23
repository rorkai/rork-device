import Foundation
import XCTest
@testable import RorkDevice

final class DeviceClientIntegrationTests: XCTestCase {
    func testDiscoverDevicesPreservesEveryRouteReportedByUSBMux() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBMuxDevice(
                deviceID: 1,
                serialNumber: "device-1",
                properties: ["ConnectionType": "Network"]
            ),
            USBMuxDevice(
                deviceID: 2,
                serialNumber: "device-1",
                properties: ["ConnectionType": "USB"]
            ),
        ])
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )

        let devices = try await client.discoverDevices()

        XCTAssertEqual(
            devices.map(\.connection),
            [.usbmux(deviceID: 1), .usbmux(deviceID: 2)]
        )
    }

    func testDiscoverDevicePrefersUSBRouteForMatchingIdentifier() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBMuxDevice(
                deviceID: 1,
                serialNumber: "device-1",
                properties: ["ConnectionType": "Network"]
            ),
            USBMuxDevice(
                deviceID: 2,
                serialNumber: "device-1",
                properties: ["ConnectionType": "USB"]
            ),
        ])
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )

        let device = try await client.discoverDevice(
            identifier: "device-1"
        )

        XCTAssertEqual(device?.connection, .usbmux(deviceID: 2))
    }

    func testDiscoverDeviceUsesNetworkRouteWhenUSBIsUnavailable() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBMuxDevice(
                deviceID: 1,
                serialNumber: "device-1",
                properties: ["ConnectionType": "Network"]
            )
        ])
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )

        let device = try await client.discoverDevice(
            identifier: "device-1"
        )

        XCTAssertEqual(device?.connection, .usbmux(deviceID: 1))
    }

    func testPairsAfterDeviceTrustApprovalAndSavesTheAcceptedRecord() async throws {
        let daemon = try FakeUSBMuxDaemon(pairingResponses: [
            [
                "Request": "Pair",
                "Error": "PairingDialogResponsePending",
            ],
            [
                "Request": "Pair",
                "EscrowBag": Data([7, 8, 9]),
            ],
        ])
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )
        let progress = EventRecorder<DevicePairingProgress>()
        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)

        let pairingRecord = try await client.pair(
            with: device,
            trustTimeout: .seconds(1),
            retryInterval: .milliseconds(1)
        ) {
            progress.append($0)
        }

        XCTAssertEqual(daemon.pairingAttemptCount, 2)
        XCTAssertEqual(
            progress.values,
            [.waitingForUserConfirmation, .savingPairingRecord]
        )
        XCTAssertEqual(pairingRecord.escrowBag, Data([7, 8, 9]))
        XCTAssertEqual(
            daemon.savedPairingRecordIdentifier,
            device.identifier
        )
        XCTAssertEqual(
            daemon.savedPairingRecordDeviceID,
            1
        )
        XCTAssertEqual(
            try PairingRecord.parse(
                XCTUnwrap(daemon.savedPairingRecordData)
            ),
            pairingRecord
        )
    }

    func testPairingTrustTimeoutCapsLongRetryInterval() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )
        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await client.pair(
                with: device,
                trustTimeout: .milliseconds(50),
                retryInterval: .seconds(2)
            )
            XCTFail("Pairing should time out while the Trust dialog is pending.")
        } catch {
            XCTAssertEqual(
                error as? LockdownPairingError,
                .timedOut
            )
        }

        XCTAssertLessThan(
            start.duration(to: clock.now),
            .seconds(1)
        )
    }

    func testPairingRejectsZeroRetryInterval() async throws {
        let client = DeviceClient()

        await XCTAssertThrowsErrorAsync({
            _ = try await client.pair(
                using: try testPairingRecord(),
                over: FailingDeviceTransport(),
                trustTimeout: .seconds(1),
                retryInterval: .zero
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput("Pairing retry interval must be greater than zero.")
            )
        }
    }

    func testUnpairsDeviceBeforeRemovingStoredPairingRecord() async throws {
        let pairingRecord = try testPairingRecord()
        let daemon = try FakeUSBMuxDaemon(
            pairingRecordData: try pairingRecord.propertyListData(
                format: .binary
            )
        )
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )
        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)

        try await client.unpair(from: device)

        XCTAssertEqual(daemon.unpairedHostIdentifier, "host-1")
        XCTAssertEqual(
            daemon.removedPairingRecordIdentifier,
            device.identifier
        )
    }

    func testUnpairKeepsStoredRecordWhenDeviceRejectsRequest() async throws {
        let pairingRecord = try testPairingRecord()
        let daemon = try FakeUSBMuxDaemon(
            pairingRecordData: try pairingRecord.propertyListData(
                format: .binary
            ),
            unpairingResponse: [
                "Request": "Unpair",
                "Result": "Failure",
                "Error": "InvalidHostID",
            ]
        )
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )
        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)

        await XCTAssertThrowsErrorAsync({
            try await client.unpair(from: device)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .lockdown("Unpair failed: InvalidHostID")
            )
        }

        XCTAssertNil(daemon.removedPairingRecordIdentifier)
    }

    func testUnpairReportsHostRecordRemovalFailureAfterRevocation() async throws {
        let pairingRecord = try testPairingRecord()
        let daemon = try FakeUSBMuxDaemon(
            pairingRecordData: try pairingRecord.propertyListData(
                format: .binary
            ),
            removePairingRecordStatus: 2
        )
        defer { daemon.stop() }
        let client = DeviceClient(
            usbmuxClient: USBMuxClient(
                host: "127.0.0.1",
                port: daemon.port
            )
        )
        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)

        await XCTAssertThrowsErrorAsync({
            try await client.unpair(from: device)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport(
                    "usbmux DeletePairRecord failed with code 2."
                )
            )
        }

        XCTAssertEqual(daemon.unpairedHostIdentifier, "host-1")
        XCTAssertEqual(
            daemon.removedPairingRecordIdentifier,
            device.identifier
        )
    }

    func testStreamsDeviceEventsThroughFakeUSBMuxDaemon() async throws {
        let daemon = try FakeUSBMuxDaemon(deviceEvents: [
            .attached(USBMuxDevice(
                deviceID: 3,
                serialNumber: "fake-device-3",
                properties: ["ConnectionType": "USB"]
            )),
            .detached(deviceID: 3, serialNumber: "fake-device-3"),
        ])
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        var events: [DeviceEvent] = []
        for try await event in client.deviceEvents() {
            events.append(event)
            if events.count == 2 {
                break
            }
        }

        XCTAssertEqual(events, [
            .attached(Device(
                identifier: "fake-device-3",
                connection: .usbmux(deviceID: 3),
                properties: [
                    "ConnectionType": "USB",
                    "SerialNumber": "fake-device-3",
                ]
            )),
            .detached(identifier: "fake-device-3", connection: .usbmux(deviceID: 3)),
        ])
    }

    func testInstallsApplicationThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))
        let ipaURL = try temporaryFile(contents: Data("fake ipa".utf8))
        defer { try? FileManager.default.removeItem(at: ipaURL) }
        let progress = EventRecorder<InstallationProgress>()

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        try await session.installApplication(
            at: ipaURL,
            bundleIdentifier: "com.example.app"
        ) {
            progress.append($0)
        }

        XCTAssertEqual(progress.values.last?.status, .complete)
        XCTAssertTrue(progress.values.map(\.status).contains(.installing))
        XCTAssertTrue(daemon.connectedPorts.contains(62078))
        XCTAssertTrue(daemon.connectedPorts.contains(1234))
        XCTAssertTrue(daemon.connectedPorts.contains(2345))
        XCTAssertContains(daemon.afcOperations, [9, 8, 9, 13, 16, 20])
        XCTAssertEqual(daemon.installedPackagePaths, ["./PublicStaging/com.example.app/app.ipa"])
    }

    func testInstallsInMemoryApplicationThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))
        let progress = EventRecorder<InstallationProgress>()

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        try await session.installApplication(
            Data("fake ipa".utf8),
            bundleIdentifier: "com.example.memory"
        ) {
            progress.append($0)
        }

        XCTAssertEqual(progress.values.last?.status, .complete)
        XCTAssertTrue(progress.values.map(\.status).contains(.installing))
        XCTAssertTrue(daemon.connectedPorts.contains(62078))
        XCTAssertTrue(daemon.connectedPorts.contains(1234))
        XCTAssertTrue(daemon.connectedPorts.contains(2345))
        XCTAssertContains(daemon.afcOperations, [9, 8, 9, 13, 16, 20])
        XCTAssertEqual(daemon.installedPackagePaths, ["./PublicStaging/com.example.memory/app.ipa"])
    }

    func testStagesApplicationDoesNotSendEscrowBagForAFCService() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord(escrowBag: Data([8])))
        let stagedPath = try await session.stageApplication(
            Data("fake ipa".utf8),
            bundleIdentifier: "com.example.escrow"
        )

        XCTAssertEqual(stagedPath, "./PublicStaging/com.example.escrow/app.ipa")
        XCTAssertTrue(daemon.servicesStartedWithEscrow.isEmpty)
    }

    func testStartServiceCanOptIntoEscrowBag() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        let connection = try await session.startService(.afc, escrowBag: Data([8]))
        connection.close()

        XCTAssertEqual(daemon.servicesStartedWithEscrow, [LockdownServiceName.afc.rawValue])
    }

    func testStartServiceCanUseRawServiceName() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        let connection = try await session.startService(named: LockdownServiceName.afc.rawValue)
        connection.close()

        XCTAssertTrue(daemon.connectedPorts.contains(1234))
    }

    func testStartsHeartbeatThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        let heartbeat = try await session.startHeartbeat(firstMessageTimeout: .seconds(2))
        defer { heartbeat.stop() }

        XCTAssertTrue(daemon.connectedPorts.contains(4567))
        try await waitUntil("heartbeat reply") {
            !daemon.heartbeatReplies.isEmpty
        }
        XCTAssertEqual(daemon.heartbeatReplies, ["Polo"])
    }

    func testOpensHouseArrestContainerThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        let afc = try await session.openApplicationContainer(
            bundleIdentifier: "com.example.app",
            scope: .container
        )
        try await afc.makeDirectory("/Documents/Test")

        XCTAssertTrue(daemon.connectedPorts.contains(5678))
        XCTAssertEqual(daemon.houseArrestRequests, [[
            "Command": "VendContainer",
            "Identifier": "com.example.app",
        ]])
        XCTAssertContains(daemon.afcOperations, [9])
    }

    func testManagesProvisioningProfilesThroughFakeUSBMuxDeviceStack() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = DeviceClient(usbmuxClient: USBMuxClient(host: "127.0.0.1", port: daemon.port))

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())

        try await session.installProvisioningProfile(Data([1, 2, 3]))
        let profiles = try await session.copyProvisioningProfiles()
        try await session.removeProvisioningProfile(identifier: "profile-uuid")

        XCTAssertEqual(profiles, [Data([9, 9, 9])])
        XCTAssertTrue(daemon.connectedPorts.contains(62078))
        XCTAssertEqual(daemon.connectedPorts.filter { $0 == 3456 }.count, 3)
        XCTAssertContains(daemon.misagentMessageTypes, ["Install", "CopyAll", "Remove"])
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

        let devices = try await client.discoverDevices()
        let device = try XCTUnwrap(devices.first)
        let session = try await client.connect(to: device, using: try testPairingRecord())
        XCTAssertEqual(upgrader.upgradeCount, 1)

        _ = try await session.stageApplication(at: ipaURL, bundleIdentifier: "com.example.app")

        XCTAssertEqual(upgrader.upgradeCount, 2)
        XCTAssertTrue(daemon.connectedPorts.contains(62078))
        XCTAssertTrue(daemon.connectedPorts.contains(1234))
    }

    func testLockdownConnectionClosesWhenSessionSetupFails() async throws {
        let connection = FakeConnection()
        let client = DeviceClient()

        await XCTAssertThrowsErrorAsync({
            _ = try await client.connect(
                over: StaticDeviceTransport(connection: connection),
                using: try testPairingRecord()
            )
        }) { _ in }

        XCTAssertTrue(connection.isClosed)
    }

    func testLockdownConnectionClosesWhenSecureUpgradeFails() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "SessionID": "fake-session",
                "EnableSessionSSL": true,
            ])
        )
        let expectedError = RorkDeviceError.secureSession(
            "Deliberate Lockdown secure-upgrade failure."
        )
        let client = DeviceClient(
            secureSessionUpgrader: FailingSecureSessionUpgrader(
                error: expectedError
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await client.connect(
                over: StaticDeviceTransport(connection: connection),
                using: try testPairingRecord()
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, expectedError)
        }

        XCTAssertTrue(connection.isClosed)
    }

    func testSecureServiceConnectionClosesWhenUpgradeFails() async throws {
        let lockdownConnection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Port": 1234,
                "EnableServiceSSL": true,
            ])
        )
        let serviceConnection = FakeConnection()
        let expectedError = RorkDeviceError.secureSession(
            "Deliberate secure-upgrade failure."
        )
        let backend = LockdownDeviceSessionBackend(
            transport: StaticDeviceTransport(connection: serviceConnection),
            lockdown: LockdownClient(connection: lockdownConnection),
            pairingRecord: try testPairingRecord(),
            secureSessionUpgrader: FailingSecureSessionUpgrader(
                error: expectedError
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await backend.startService(
                named: LockdownServiceName.afc.rawValue,
                escrowBag: nil
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, expectedError)
        }

        XCTAssertTrue(serviceConnection.isClosed)
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

/// Returns one preconstructed connection for backend ownership tests.
private struct StaticDeviceTransport: DeviceTransport {
    /// Connection handed to the first service request.
    let connection: DeviceConnection

    /// Returns the preconstructed connection without opening a real transport.
    func connect(to _: UInt16) async throws -> DeviceConnection {
        connection
    }
}

/// Ensures invalid-input tests fail if validation reaches device I/O.
///
/// The zero-interval regression must be rejected before opening a transport;
/// throwing here makes that ordering observable without a physical device.
private struct FailingDeviceTransport: DeviceTransport {
    /// Rejects the unexpected connection attempt.
    func connect(to _: UInt16) async throws -> DeviceConnection {
        throw RorkDeviceError.transport(
            "The transport should not be opened for invalid input."
        )
    }
}

/// Fails every secure-session upgrade with a caller-supplied error.
private struct FailingSecureSessionUpgrader: SecureSessionUpgrader {
    /// Error propagated from `upgrade(_:pairingRecord:)`.
    let error: Error

    /// Rejects the upgrade so the backend's cleanup path can be observed.
    func upgrade(
        _: DeviceConnection,
        pairingRecord _: PairingRecord
    ) async throws -> DeviceConnection {
        throw error
    }
}

private func testPairingRecord(escrowBag: Data? = nil) throws -> PairingRecord {
    var plist: [String: Any] = [
        "UDID": "fake-device-1",
        "HostID": "host-1",
        "SystemBUID": "system-1",
        "DeviceCertificate": Data([1]),
        "HostCertificate": Data([2]),
        "HostPrivateKey": Data([3]),
        "RootCertificate": Data([4]),
        "RootPrivateKey": Data([5]),
    ]
    if let escrowBag {
        plist["EscrowBag"] = escrowBag
    }

    return try PairingRecord.parse(
        PropertyListSerialization.data(
            fromPropertyList: plist,
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

/// Waits for an asynchronously recorded integration-test condition.
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func XCTAssertContains<T: Equatable>(
    _ values: [T],
    _ expectedValues: [T],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for expected in expectedValues {
        XCTAssertTrue(values.contains(expected), "Expected \(values) to contain \(expected).", file: file, line: line)
    }
}
