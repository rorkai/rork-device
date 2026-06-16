import XCTest
@testable import RorkDevice

final class USBMuxClientIntegrationTests: XCTestCase {
    func testListsDevicesFromFakeDaemon() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        let devices = try await client.listDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, 1)
        XCTAssertEqual(devices.first?.serialNumber, "fake-device-1")
        XCTAssertEqual(devices.first?.properties["ConnectionType"], "USB")
    }

    func testConnectSendsNormalizedDevicePort() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        let device = USBMuxDevice(deviceID: 1, serialNumber: "fake-device-1", properties: [:])
        let connection = try await client.connect(to: device, port: 62078)
        connection.close()

        XCTAssertEqual(daemon.connectedPorts, [62078])
    }

    func testReadsPairingRecordAndSuppliesDeviceIdentifier() async throws {
        let recordData = try PropertyListSerialization.data(
            fromPropertyList: [
                "HostID": "host-1",
                "SystemBUID": "system-1",
                "DeviceCertificate": Data([1]),
                "HostCertificate": Data([2]),
                "HostPrivateKey": Data([3]),
            ],
            format: .binary,
            options: 0
        )
        let daemon = try FakeUSBMuxDaemon(pairingRecordData: recordData)
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        let pairingRecord = try await client.pairingRecord(
            for: "fake-device-1"
        )

        XCTAssertEqual(pairingRecord.udid, "fake-device-1")
        XCTAssertEqual(pairingRecord.hostID, "host-1")
        XCTAssertEqual(pairingRecord.systemBUID, "system-1")
        XCTAssertEqual(pairingRecord.deviceCertificate, Data([1]))
    }

    func testDeviceEventsStreamsAttachAndDetachMessages() async throws {
        let attached = USBMuxDevice(
            deviceID: 7,
            serialNumber: "attached-device",
            properties: [
                "ConnectionType": "USB",
                "SerialNumber": "attached-device",
            ]
        )
        let daemon = try FakeUSBMuxDaemon(deviceEvents: [
            .attached(attached),
            .detached(deviceID: 7, serialNumber: "attached-device"),
        ])
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        var events: [USBMuxDeviceEvent] = []
        for try await event in client.deviceEvents() {
            events.append(event)
            if events.count == 2 {
                break
            }
        }

        XCTAssertEqual(events, [
            .attached(attached),
            .detached(deviceID: 7, serialNumber: "attached-device"),
        ])
    }

    func testDeviceEventsCompletesWhenListenSocketCloses() async throws {
        let attached = USBMuxDevice(
            deviceID: 9,
            serialNumber: "short-lived-device",
            properties: [
                "ConnectionType": "USB",
                "SerialNumber": "short-lived-device",
            ]
        )
        let daemon = try FakeUSBMuxDaemon(deviceEvents: [.attached(attached)])
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        var iterator = client.deviceEvents().makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()

        XCTAssertEqual(first, .attached(attached))
        XCTAssertNil(second)
    }

    func testDeviceEventsClosesListenSocketWhenCancelled() async throws {
        let daemon = try FakeUSBMuxDaemon(keepListenOpenAfterEvents: true)
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)
        let task = Task {
            do {
                for try await _ in client.deviceEvents() {}
            } catch {}
        }

        try await waitUntil("usbmux Listen connection opens") {
            daemon.listenConnectionOpen
        }
        task.cancel()
        try await waitUntil("usbmux Listen connection closes") {
            daemon.listenPeerClosed
        }
        await task.value
    }

    func testDeviceEventsRejectsListenResponseWithoutNumber() async throws {
        let daemon = try FakeUSBMuxDaemon(listenResponse: [:])
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        var iterator = client.deviceEvents().makeAsyncIterator()

        await XCTAssertThrowsErrorAsync({ _ = try await iterator.next() }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("usbmux Listen response was missing Number.")
            )
        }
    }
}

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
