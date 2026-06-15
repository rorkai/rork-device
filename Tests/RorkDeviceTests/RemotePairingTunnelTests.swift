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

    func testRejectsUnavailableBackendBeforeOpeningControlConnection() async throws {
        let backend = RecordingRemotePairingTransportBackend(isAvailable: false)

        await XCTAssertThrowsErrorAsync({
            _ = try await RemotePairingTunnel.connect(
                to: "192.0.2.1",
                using: remotePairingIdentity(),
                backend: backend
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .secureSessionUnsupported)
        }

        XCTAssertEqual(backend.controlConnectionAttempts, 0)
    }

    func testUsesBackendToOpenControlConnection() async throws {
        let expectedError = RorkDeviceError.transport("Stop after recording the request.")
        let backend = RecordingRemotePairingTransportBackend(
            isAvailable: true,
            controlConnectionError: expectedError
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await RemotePairingTunnel.connect(
                to: "192.0.2.1",
                port: 49_153,
                using: remotePairingIdentity(),
                timeout: .seconds(3),
                backend: backend
            )
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, expectedError)
        }

        XCTAssertEqual(backend.controlConnectionAttempts, 1)
        XCTAssertEqual(backend.lastControlHost, "192.0.2.1")
        XCTAssertEqual(backend.lastControlPort, 49_153)
        XCTAssertEqual(backend.lastControlTimeout, .seconds(3))
        XCTAssertTrue(backend.usedSystemDefaultRoute)
    }

    func testExposesTheTLSCipherSuiteReportedByTheTransport() {
        let tunnel = RemotePairingTunnel(
            configuration: tunnelConfiguration(),
            tlsCipherSuite: "TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8)",
            controlConnection: FakeConnection(),
            tunnelConnection: FakeConnection()
        )

        XCTAssertEqual(
            tunnel.tlsCipherSuite,
            "TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8)"
        )
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

private final class RecordingRemotePairingTransportBackend: RemotePairingTransportBackend {
    let isAvailable: Bool
    private let controlConnectionError: Error?

    private(set) var controlConnectionAttempts = 0
    private(set) var lastControlHost: String?
    private(set) var lastControlPort: UInt16?
    private(set) var lastControlTimeout: Duration?
    private(set) var usedSystemDefaultRoute = false

    init(
        isAvailable: Bool,
        controlConnectionError: Error? = nil
    ) {
        self.isAvailable = isAvailable
        self.controlConnectionError = controlConnectionError
    }

    func openControlConnection(
        to host: String,
        port: UInt16,
        route: RemotePairingTransportRoute,
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
        preSharedKey _: Data,
        route _: RemotePairingTransportRoute,
        timeout _: Duration
    ) async throws -> RemotePairingTLSConnection {
        throw RorkDeviceError.transport("TLS connection was not expected.")
    }
}

private func remotePairingIdentity() -> RemotePairingIdentity {
    RemotePairingIdentity(
        identifier: "test-host",
        privateKeyData: Data(repeating: 1, count: 32)
    )
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
