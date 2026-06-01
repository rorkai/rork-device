import XCTest
@testable import RorkDevice

final class USBMuxClientIntegrationTests: XCTestCase {
    func testListsDevicesFromFakeDaemon() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        let devices = try await client.devices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, 1)
        XCTAssertEqual(devices.first?.serialNumber, "fake-device-1")
        XCTAssertEqual(devices.first?.properties["ConnectionType"], "USB")
    }

    func testConnectSendsNormalizedDevicePort() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }
        let client = USBMuxClient(host: "127.0.0.1", port: daemon.port)

        let connection = try await client.connect(deviceID: 1, port: 62078)
        connection.close()

        XCTAssertEqual(daemon.connectedPorts, [62078])
    }
}
