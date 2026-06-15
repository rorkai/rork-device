import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingTunnelTests: XCTestCase {
    func testSendsAndReceivesIPv6Packets() async throws {
        let inboundPacket = ipv6Packet(payload: Data([0x10, 0x20]))
        let controlConnection = FakeConnection()
        let tunnelConnection = FakeConnection(inbound: inboundPacket)
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: controlConnection,
            tunnelConnection: tunnelConnection
        )
        let outboundPacket = ipv6Packet(payload: Data([0x30, 0x40, 0x50]))

        try await tunnel.sendPacket(outboundPacket)
        let receivedPacket = try await tunnel.receivePacket()

        XCTAssertEqual(tunnelConnection.sent, [outboundPacket])
        XCTAssertEqual(receivedPacket, inboundPacket)
    }

    func testRejectsNonIPv6Packet() async throws {
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )

        await XCTAssertThrowsErrorAsync({
            try await tunnel.sendPacket(Data([0x45, 0, 0, 0]))
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput("Remote pairing tunnel only accepts IPv6 packets.")
            )
        }
    }

    func testCloseClosesControlAndTunnelConnections() {
        let controlConnection = FakeConnection()
        let tunnelConnection = FakeConnection()
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: controlConnection,
            tunnelConnection: tunnelConnection
        )

        tunnel.close()

        XCTAssertTrue(controlConnection.isClosed)
        XCTAssertTrue(tunnelConnection.isClosed)
    }
}

private func tunnelConfiguration() -> RemotePairingTunnelConfiguration {
    RemotePairingTunnelConfiguration(
        hostAddress: "fd00::1",
        deviceAddress: "fd00::2",
        networkMask: "ffff:ffff:ffff:ffff::",
        maximumTransmissionUnit: 16_000,
        serviceDiscoveryPort: 58_000
    )
}

private func ipv6Packet(payload: Data) -> Data {
    var header = Data(repeating: 0, count: 40)
    header[0] = 0x60
    header[4] = UInt8(payload.count >> 8)
    header[5] = UInt8(payload.count & 0xff)
    return header + payload
}
