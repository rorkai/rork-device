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
}
