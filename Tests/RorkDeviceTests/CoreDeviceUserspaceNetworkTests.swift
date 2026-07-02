import XCTest
@testable import RorkDevice

/// Tests userspace-network ownership across supported packet tunnels.
final class CoreDeviceUserspaceNetworkTests: XCTestCase {
    /// Statistics reflect packets pumped through the network in both directions.
    func testCountsForwardedPacketsInStatistics() async throws {
        let controlConnection = FakeConnection()
        let packetConnection = FakeConnection(
            inbound: minimalIPv6Packet(),
            blocksWhenDrained: true
        )
        let configuration = CoreDeviceTunnelConfiguration(
            hostAddress: "fd00::2",
            deviceAddress: "fd00::1",
            networkMask: "ffff:ffff:ffff:ffff::",
            maximumTransmissionUnit: 1_280,
            serviceDiscoveryPort: 58_783
        )
        let tunnel = RemotePairingTunnel(
            configuration: configuration,
            controlConnection: controlConnection,
            tunnelConnection: packetConnection
        )
        let network = try CoreDeviceUserspaceNetwork(tunnel: tunnel)
        defer {
            network.close()
        }

        let connectTask = Task {
            // The handshake never completes against the fake peer; the SYN
            // traffic it generates is what the statistics assertions observe.
            let connection = try? await network.connect(to: 58_783)
            connection?.close()
        }
        defer {
            connectTask.cancel()
        }

        try await waitUntil("the network counts both packet directions") {
            let statistics = network.statistics()
            return statistics.packetsReceived == 1
                && statistics.packetsSent >= 1
        }
        let statistics = network.statistics()
        XCTAssertEqual(statistics.bytesReceived, 40)
        XCTAssertGreaterThanOrEqual(statistics.bytesSent, 40)
        XCTAssertGreaterThanOrEqual(statistics.activeConnections, 1)
        XCTAssertGreaterThanOrEqual(
            statistics.ip6PacketsReceived,
            1
        )
        XCTAssertGreaterThanOrEqual(statistics.tcpSegmentsSent, 1)
    }

    /// Builds one header-only IPv6 packet addressed to the network's host side.
    private func minimalIPv6Packet() -> Data {
        var packet = Data(count: 40)
        packet[0] = 0x60
        packet[6] = 59
        packet[7] = 64
        packet[8] = 0xFD
        packet[23] = 0x01
        packet[24] = 0xFD
        packet[39] = 0x02
        return packet
    }

    /// Polls a condition until it holds or a bounded deadline passes.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting until \(description).")
    }

    /// Remote-pairing tunnels can carry the userspace network and close with it.
    func testCreatesNetworkFromRemotePairingTunnel() throws {
        let controlConnection = FakeConnection()
        let packetConnection = FakeConnection()
        let configuration = CoreDeviceTunnelConfiguration(
            hostAddress: "fd00::2",
            deviceAddress: "fd00::1",
            networkMask: "ffff:ffff:ffff:ffff::",
            maximumTransmissionUnit: 1_280,
            serviceDiscoveryPort: 58_783
        )
        let tunnel = RemotePairingTunnel(
            configuration: configuration,
            controlConnection: controlConnection,
            tunnelConnection: packetConnection
        )

        let network = try CoreDeviceUserspaceNetwork(tunnel: tunnel)
        XCTAssertEqual(network.configuration, configuration)

        network.close()

        XCTAssertTrue(controlConnection.isClosed)
        XCTAssertTrue(packetConnection.isClosed)
    }
}
