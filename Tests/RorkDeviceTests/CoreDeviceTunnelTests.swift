import Foundation
import XCTest
@testable import RorkDevice

final class CoreDeviceTunnelTests: XCTestCase {
    func testDeviceSessionOpensCoreDeviceTunnel() async throws {
        let packet = ipv6Packet(payload: Data([0x10, 0x20]))
        let connection = try coreDeviceConnection(
            packetAfterHandshake: packet
        )
        let backend = CoreDeviceTunnelSessionBackend(connection: connection)
        let session = DeviceSession(backend: backend)

        let tunnel = try await session.openCoreDeviceTunnel(
            requestedMaximumTransmissionUnit: 1_280
        )

        XCTAssertEqual(
            backend.startedServices,
            [LockdownServiceName.coreDeviceProxy.rawValue]
        )
        XCTAssertEqual(
            tunnel.configuration,
            CoreDeviceTunnelConfiguration(
                hostAddress: "fd00::2",
                deviceAddress: "fd00::1",
                networkMask: "ffff:ffff:ffff:ffff::",
                maximumTransmissionUnit: 1_280,
                serviceDiscoveryPort: 58_783
            )
        )
        let request = try XCTUnwrap(connection.sent.first)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: request.dropFirst(10)
            ) as? [String: Any]
        )
        XCTAssertEqual(requestObject["mtu"] as? Int, 1_280)

        let receivedPacket = try await tunnel.receivePacket()
        XCTAssertEqual(receivedPacket, packet)
    }

    func testCoreDeviceTunnelSendsPacketsAndClosesItsService() async throws {
        let connection = try coreDeviceConnection()
        let session = DeviceSession(
            backend: CoreDeviceTunnelSessionBackend(
                connection: connection
            )
        )
        let tunnel = try await session.openCoreDeviceTunnel()
        let packet = ipv6Packet(payload: Data([0x30, 0x40]))

        try await tunnel.sendPacket(packet)
        tunnel.close()

        XCTAssertEqual(connection.sent.last, packet)
        XCTAssertTrue(connection.isClosed)
    }

    func testFailedCoreDeviceNegotiationClosesItsService() async {
        let connection = FakeConnection(inbound: Data("invalid".utf8))
        let session = DeviceSession(
            backend: CoreDeviceTunnelSessionBackend(
                connection: connection
            )
        )

        await XCTAssertThrowsErrorAsync(
            {
                _ = try await session.openCoreDeviceTunnel()
            },
            { _ in }
        )

        XCTAssertTrue(connection.isClosed)
    }
}

private final class CoreDeviceTunnelSessionBackend: DeviceSessionBackend {
    private let connection: DeviceConnection

    private(set) var startedServices: [String] = []

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedServices.append(serviceName)
        return connection
    }
}

private func coreDeviceConnection(
    packetAfterHandshake: Data = Data()
) throws -> FakeConnection {
    let response = try JSONSerialization.data(withJSONObject: [
        "clientParameters": [
            "address": "fd00::2",
            "netmask": "ffff:ffff:ffff:ffff::",
            "mtu": 1_280,
        ],
        "serverAddress": "fd00::1",
        "serverRSDPort": 58_783,
    ])
    var inbound = Data("CDTunnel".utf8)
    inbound.appendBigEndian(UInt16(response.count))
    inbound.append(response)
    inbound.append(packetAfterHandshake)
    return FakeConnection(inbound: inbound)
}

private func ipv6Packet(payload: Data) -> Data {
    var header = Data(repeating: 0, count: 40)
    header[0] = 0x60
    header[4] = UInt8(payload.count >> 8)
    header[5] = UInt8(payload.count & 0xff)
    return header + payload
}
