import Foundation
import XCTest
@testable import RorkDevice

final class CDTunnelProtocolTests: XCTestCase {
    func testHandshakeParsesTunnelConfiguration() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "clientParameters": [
                "address": "fd00::2",
                "netmask": "ffff:ffff:ffff:ffff::",
                "mtu": 1400,
            ],
            "serverAddress": "fd00::1",
            "serverRSDPort": 58783,
        ])
        var inbound = Data("CDTunnel".utf8)
        inbound.appendBigEndian(UInt16(response.count))
        inbound.append(response)
        let connection = FakeConnection(inbound: inbound)

        let configuration = try await CDTunnelProtocol.negotiateConfiguration(
            over: connection,
            requestedMaximumTransmissionUnit: 16_000
        )

        XCTAssertEqual(
            configuration,
            RemotePairingTunnelConfiguration(
                hostAddress: "fd00::2",
                deviceAddress: "fd00::1",
                networkMask: "ffff:ffff:ffff:ffff::",
                maximumTransmissionUnit: 1400,
                serviceDiscoveryPort: 58_783
            )
        )
        let request = try XCTUnwrap(connection.sent.first)
        XCTAssertTrue(request.starts(with: Data("CDTunnel".utf8)))
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.dropFirst(10)) as? [String: Any]
        )
        XCTAssertEqual(requestObject["type"] as? String, "clientHandshakeRequest")
        XCTAssertEqual(requestObject["mtu"] as? Int, 16000)
    }

    func testReceivesCompleteIPv6Packet() async throws {
        var packet = Data(repeating: 0, count: 40)
        packet[0] = 0x60
        packet[4] = 0
        packet[5] = 4
        packet.append(Data([1, 2, 3, 4]))
        let connection = FakeConnection(inbound: packet)

        let received = try await CDTunnelProtocol.receivePacket(from: connection)

        XCTAssertEqual(received, packet)
    }

    func testRejectsNonIPv6Packet() async throws {
        var packet = Data(repeating: 0, count: 40)
        packet[0] = 0x40
        let connection = FakeConnection(inbound: packet)

        do {
            _ = try await CDTunnelProtocol.receivePacket(from: connection)
            XCTFail("Expected non-IPv6 packet to fail.")
        } catch {
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("CDTunnel received a packet without an IPv6 header.")
            )
        }
    }
}
