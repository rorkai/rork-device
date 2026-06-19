import XCTest
@testable import RorkDevice

/// Tests userspace-network ownership across supported packet tunnels.
final class CoreDeviceUserspaceNetworkTests: XCTestCase {
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
