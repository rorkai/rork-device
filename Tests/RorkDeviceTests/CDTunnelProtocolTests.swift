import Foundation
import XCTest
@testable import RorkDevice

final class CDTunnelProtocolTests: XCTestCase {
    func testHandshakeParsesTunnelConfiguration() async throws {
        let response: [String: Any] = [
            "clientParameters": [
                "address": "fd00::2",
                "netmask": "ffff:ffff:ffff:ffff::",
                "mtu": 1400,
            ],
            "serverAddress": "fd00::1",
            "serverRSDPort": 58783,
        ]
        let connection = try handshakeConnection(response: response)

        let configuration = try await CDTunnelProtocol.negotiateConfiguration(
            over: connection,
            requestedMaximumTransmissionUnit: 16_000
        )

        XCTAssertEqual(
            configuration,
            CoreDeviceTunnelConfiguration(
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

    func testHandshakeRejectsMissingNetworkMask() async throws {
        let connection = try handshakeConnection(response: [
            "clientParameters": [
                "address": "fd00::2",
                "mtu": 1400,
            ],
            "serverAddress": "fd00::1",
            "serverRSDPort": 58783,
        ])

        await assertHandshakeRejectsInvalidNetworkParameters(connection)
    }

    func testHandshakeRejectsFractionalMTU() async throws {
        let connection = try handshakeConnection(response: [
            "clientParameters": [
                "address": "fd00::2",
                "netmask": "ffff:ffff:ffff:ffff::",
                "mtu": 1400.5,
            ],
            "serverAddress": "fd00::1",
            "serverRSDPort": 58783,
        ])

        await assertHandshakeRejectsInvalidNetworkParameters(connection)
    }

    func testHandshakeRejectsBooleanServiceDiscoveryPort() async throws {
        let connection = try handshakeConnection(response: [
            "clientParameters": [
                "address": "fd00::2",
                "netmask": "ffff:ffff:ffff:ffff::",
                "mtu": 1400,
            ],
            "serverAddress": "fd00::1",
            "serverRSDPort": true,
        ])

        await assertHandshakeRejectsInvalidNetworkParameters(connection)
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

    /// Creates the framed server response consumed by tunnel negotiation.
    private func handshakeConnection(
        response: [String: Any]
    ) throws -> FakeConnection {
        let responseData = try JSONSerialization.data(withJSONObject: response)
        var inbound = Data("CDTunnel".utf8)
        inbound.appendBigEndian(UInt16(responseData.count))
        inbound.append(responseData)
        return FakeConnection(inbound: inbound)
    }

    /// Verifies malformed handshake numbers fail at the protocol boundary.
    private func assertHandshakeRejectsInvalidNetworkParameters(
        _ connection: FakeConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync(
            {
                _ = try await CDTunnelProtocol.negotiateConfiguration(
                    over: connection,
                    requestedMaximumTransmissionUnit: 16_000
                )
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .protocolViolation(
                        "CDTunnel handshake response is missing network parameters."
                    ),
                    file: file,
                    line: line
                )
            },
            file: file,
            line: line
        )
    }
}
