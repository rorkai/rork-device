import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingTunnelTests: XCTestCase {
    func testReportsWhetherTheCurrentPlatformSupportsRemotePairingTLS() {
        #if canImport(Network) && canImport(Security)
        XCTAssertTrue(RemotePairingTunnel.isSupported)
        #else
        XCTAssertFalse(RemotePairingTunnel.isSupported)
        #endif
    }

    #if !canImport(Network) || !canImport(Security)
    func testConnectRejectsUnsupportedPlatformBeforeOpeningNetworkConnection() async throws {
        await XCTAssertThrowsErrorAsync({
            _ = try await RemotePairingTunnel.connect(
                to: "192.0.2.1",
                using: remotePairingIdentity()
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .secureSessionUnsupported)
        }
    }
    #endif

    func testUsesTransportToOpenControlConnection() async throws {
        let expectedError = RorkDeviceError.transport("Stop after recording the request.")
        let transport = RecordingRemotePairingTransport(
            controlConnectionError: expectedError
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await RemotePairingTunnel.connect(
                to: "192.0.2.1",
                port: 49_153,
                using: remotePairingIdentity(),
                timeout: .seconds(3),
                transport: transport
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, expectedError)
        }

        XCTAssertEqual(transport.controlConnectionAttempts, 1)
        XCTAssertEqual(transport.lastControlHost, "192.0.2.1")
        XCTAssertEqual(transport.lastControlPort, 49_153)
        XCTAssertEqual(transport.lastControlTimeout, .seconds(3))
        XCTAssertTrue(transport.usedSystemDefaultRoute)
    }

    func testExposesTheTLSCipherSuiteReportedByTheTransport() {
        let cipherSuite = RemotePairingTLSCipherSuite(rawValue: 0x00A8)
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            tlsCipherSuite: cipherSuite,
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )

        XCTAssertEqual(tunnel.tlsCipherSuite, cipherSuite)
    }

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

    func testConcurrentSendsDoNotOverlapTransportWrites() async throws {
        let tunnelConnection = ConcurrentSendRecordingConnection()
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: FakeConnection(),
            tunnelConnection: tunnelConnection
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for byte in UInt8(0)..<20 {
                group.addTask {
                    try await tunnel.sendPacket(
                        ipv6Packet(payload: Data([byte]))
                    )
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(tunnelConnection.maximumConcurrentSendCount, 1)
    }

    func testRejectsNonIPv6Packet() async throws {
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )
        var packet = Data(repeating: 0, count: 40)
        packet[0] = 0x45

        await XCTAssertThrowsErrorAsync({
            try await tunnel.sendPacket(packet)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput("Remote pairing tunnel only accepts IPv6 packets.")
            )
        }
    }

    func testRejectsPacketShorterThanTheIPv6Header() async throws {
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )
        var packet = Data(repeating: 0, count: 39)
        packet[0] = 0x60

        await XCTAssertThrowsErrorAsync({
            try await tunnel.sendPacket(packet)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Remote pairing tunnel packet is shorter than the 40-byte IPv6 header."
                )
            )
        }
    }

    func testRejectsPacketWhosePayloadLengthDoesNotMatchItsHeader() async throws {
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )
        var packet = ipv6Packet(payload: Data([0x01, 0x02]))
        packet[5] = 3

        await XCTAssertThrowsErrorAsync({
            try await tunnel.sendPacket(packet)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Remote pairing tunnel packet length does not match its IPv6 header."
                )
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

private final class RecordingRemotePairingTransport: RemotePairingTransport {
    private let controlConnectionError: Error?

    private(set) var controlConnectionAttempts = 0
    private(set) var lastControlHost: String?
    private(set) var lastControlPort: UInt16?
    private(set) var lastControlTimeout: Duration?
    private(set) var usedSystemDefaultRoute = false

    init(controlConnectionError: Error? = nil) {
        self.controlConnectionError = controlConnectionError
    }

    func openControlConnection(
        to host: String,
        port: UInt16,
        over route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> DeviceConnection {
        controlConnectionAttempts += 1
        lastControlHost = host
        lastControlPort = port
        lastControlTimeout = timeout
        if case .systemDefault = route {
            usedSystemDefaultRoute = true
        }
        if let controlConnectionError {
            throw controlConnectionError
        }
        return FakeConnection()
    }

    func openTLSConnection(
        to _: String,
        port _: UInt16,
        using _: Data,
        over _: RemotePairingTransportRoute,
        timeout _: Duration
    ) async throws -> RemotePairingTLSConnection {
        throw RorkDeviceError.transport("TLS connection was not expected.")
    }
}

private final class ConcurrentSendRecordingConnection: DeviceConnection {
    private let lock = NSLock()
    private var activeSendCount = 0
    private var recordedMaximumConcurrentSendCount = 0

    var maximumConcurrentSendCount: Int {
        lock.withLock {
            recordedMaximumConcurrentSendCount
        }
    }

    func send(_: Data) async throws {
        lock.withLock {
            activeSendCount += 1
            recordedMaximumConcurrentSendCount = max(
                recordedMaximumConcurrentSendCount,
                activeSendCount
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        lock.withLock {
            activeSendCount -= 1
        }
    }

    func receive(exactly _: Int) async throws -> Data {
        throw RorkDeviceError.transport("Receive was not expected.")
    }

    func close() {}
}

private func remotePairingIdentity() -> RemotePairingIdentity {
    RemotePairingIdentity(
        identifier: "test-host",
        privateKey: Curve25519.Signing.PrivateKey(),
        identityResolvingKey: Data(repeating: 0x7a, count: 16)
    )
}

private func tunnelConfiguration() -> CoreDeviceTunnelConfiguration {
    CoreDeviceTunnelConfiguration(
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
