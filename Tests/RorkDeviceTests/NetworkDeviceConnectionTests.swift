#if canImport(Network)
import Darwin
import Network
import XCTest
@testable import RorkDevice

final class NetworkDeviceConnectionTests: XCTestCase {
    func testSwiftNIOConnectionUsesProvidedIPv4Interface() async throws {
        let server = try FakeUSBMuxDaemon()
        defer { server.stop() }
        let loopbackIndex = if_nametoindex("lo0")
        XCTAssertNotEqual(loopbackIndex, 0)

        let connection = try await TCPDeviceConnection.connect(
            to: "127.0.0.1",
            port: server.port,
            boundToIPv4Interface: loopbackIndex,
            timeout: .seconds(1)
        )
        connection.close()
    }

    func testSwiftNIOConnectionRejectsUnknownIPv4Interface() async throws {
        let server = try FakeUSBMuxDaemon()
        defer { server.stop() }

        await XCTAssertThrowsErrorAsync({
            _ = try await TCPDeviceConnection.connect(
                to: "127.0.0.1",
                port: server.port,
                boundToIPv4Interface: 1_000_000,
                timeout: .seconds(1)
            )
        }) { _ in }
    }

    func testTLSParametersRequireProvidedInterface() async throws {
        let interface = try await loopbackInterface()

        let parameters = NetworkDeviceConnection.makeTLSParameters(
            preSharedKey: Data([0x01, 0x02, 0x03]),
            through: interface
        )

        XCTAssertEqual(parameters.requiredInterface, interface)
    }

    func testRemotePairingCipherSuiteDescriptionUsesIANANameAndCode() {
        XCTAssertEqual(
            remotePairingTLSCipherSuiteDescription(rawValue: 0x00AF),
            "TLS_PSK_WITH_AES_256_CBC_SHA384 (0x00AF)"
        )
        XCTAssertEqual(
            remotePairingTLSCipherSuiteDescription(rawValue: 0x00A8),
            "TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8)"
        )
        XCTAssertEqual(
            remotePairingTLSCipherSuiteDescription(rawValue: 0x008C),
            "TLS_PSK_WITH_AES_128_CBC_SHA (0x008C)"
        )
    }

    func testRemotePairingCipherSuiteDescriptionPreservesUnknownCode() {
        XCTAssertEqual(
            remotePairingTLSCipherSuiteDescription(rawValue: 0x1234),
            "unknown TLS cipher suite (0x1234)"
        )
    }

    private func loopbackInterface() async throws -> NWInterface {
        let monitor = NWPathMonitor(requiredInterfaceType: .loopback)
        let expectation = expectation(description: "Resolve the loopback interface")
        let result = ResolvedNetworkInterface()

        monitor.pathUpdateHandler = { path in
            guard let interface = path.availableInterfaces.first(where: { $0.type == .loopback }),
                  result.storeIfEmpty(interface) else {
                return
            }
            monitor.cancel()
            expectation.fulfill()
        }
        monitor.start(queue: DispatchQueue(label: "dev.rork.rork-device.tests.loopback-interface"))

        await fulfillment(of: [expectation], timeout: 2)
        return try XCTUnwrap(result.value)
    }
}

private final class ResolvedNetworkInterface: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: NWInterface?

    var value: NWInterface? {
        lock.withLock { storedValue }
    }

    func storeIfEmpty(_ interface: NWInterface) -> Bool {
        lock.withLock {
            guard storedValue == nil else {
                return false
            }
            storedValue = interface
            return true
        }
    }
}
#endif
