import Foundation
import XCTest
@testable import RorkDevice

final class RemoteServiceDiscoveryTests: XCTestCase {
    func testConnectsToRemoteServicesUsingDeviceTransport() async throws {
        let discoveryConnection = FakeConnection(
            inbound: try remoteServiceDiscoveryInbound()
        )
        var serviceResponses = Data()
        serviceResponses.append(
            try PropertyListMessageFramer.encode([
                "Request": "RSDCheckin",
            ])
        )
        serviceResponses.append(
            try PropertyListMessageFramer.encode([
                "Request": "StartService",
            ])
        )
        let serviceConnection = FakeConnection(
            inbound: serviceResponses
        )
        let transport = RemoteServiceTestTransport(connections: [
            51_000: discoveryConnection,
            51_001: serviceConnection,
        ])

        let session = try await DeviceClient().connect(
            toRemoteServicesUsing: transport,
            discoveryPort: 51_000,
            label: "RorkAppInstaller"
        )
        let openedConnection = try await session.startService(.afc)

        XCTAssertTrue(openedConnection === serviceConnection)
        XCTAssertEqual(transport.requestedPorts, [51_000, 51_001])
    }

    func testOpensRemoteXPCAndParsesAdvertisedServices() async throws {
        let connection = FakeConnection(
            inbound: try remoteServiceDiscoveryInbound()
        )

        let discovery = try await RemoteServiceDiscoverySession.open(over: connection)

        XCTAssertEqual(discovery.directory.deviceIdentifier, "device-1")
        XCTAssertEqual(discovery.directory.port(for: "com.apple.afc"), 51_001)
        XCTAssertEqual(
            discovery.directory.port(for: "com.apple.mobile.installation_proxy"),
            51_002
        )
        XCTAssertEqual(
            connection.sent.first,
            Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        )
        XCTAssertFalse(connection.isClosed)

        discovery.close()

        XCTAssertTrue(connection.isClosed)
    }

    func testReassemblesHandshakeSplitAcrossHTTP2DataFrames() async throws {
        let wrapper = try XCTUnwrap(Data(base64Encoded: remoteServiceHandshakeWrapper))
        let splitIndex = wrapper.count / 2
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: wrapper.prefix(splitIndex)
            )
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: wrapper.dropFirst(splitIndex)
            )
        )
        let connection = FakeConnection(inbound: inbound)

        let discovery = try await RemoteServiceDiscoverySession.open(over: connection)

        XCTAssertEqual(discovery.directory.deviceIdentifier, "device-1")
        XCTAssertEqual(discovery.directory.services.count, 2)
    }

    func testIgnoresReplyStreamDataWhileWaitingForServiceDirectory() async throws {
        let wrapper = try XCTUnwrap(
            Data(base64Encoded: remoteServiceHandshakeWrapper)
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: Data(repeating: 0xaa, count: 1024)
            )
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: wrapper
            )
        )

        let discovery = try await RemoteServiceDiscoverySession.open(
            over: FakeConnection(inbound: inbound)
        )

        XCTAssertEqual(discovery.directory.deviceIdentifier, "device-1")
    }

    func testRejectsRemoteXPCBodyLargerThanGlobalLimit() throws {
        var wrapper = Data()
        wrapper.appendLittleEndian(UInt32(0x29b00b92))
        wrapper.appendLittleEndian(UInt32(0))
        wrapper.appendLittleEndian(UInt64(16 * 1024 * 1024 + 1))
        wrapper.appendLittleEndian(UInt64(0))

        XCTAssertThrowsError(
            try RemoteXPCMessageCodec.decodeFirstMessage(from: wrapper)
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "RemoteXPC message body exceeds the 16 MiB limit."
                )
            )
        }
    }
}

private final class RemoteServiceTestTransport: DeviceTransport {
    private let connections: [UInt16: DeviceConnection]
    private(set) var requestedPorts: [UInt16] = []

    init(connections: [UInt16: DeviceConnection]) {
        self.connections = connections
    }

    func connect(to port: UInt16) async throws -> DeviceConnection {
        requestedPorts.append(port)
        guard let connection = connections[port] else {
            throw RorkDeviceError.transport(
                "No test connection for port \(port)."
            )
        }
        return connection
    }
}

private let remoteServiceHandshakeWrapper =
    "kguwKQEBAAAcAQAAAAAAAAAAAAAAAAAAQjcTQgUAAAAA8AAADAEAAAMAAABNZXNzYWdlVHlwZQAAkAAACgAAAEhhbmRzaGFrZQAAAFByb3BlcnRpZXMAAADwAAAoAAAAAQAAAFVuaXF1ZURldmljZUlEAAAAkAAACQAAAGRldmljZS0xAAAAAFNlcnZpY2VzAAAAAADwAACYAAAAAgAAAGNvbS5hcHBsZS5hZmMuc2hpbS5yZW1vdGUAAAAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDEAAABjb20uYXBwbGUubW9iaWxlLmluc3RhbGxhdGlvbl9wcm94eS5zaGltLnJlbW90ZQAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDIAAAA="

/// Builds a complete discovery stream after RemoteXPC channel startup.
private func remoteServiceDiscoveryInbound() throws -> Data {
    var inbound = try remoteXPCSessionHandshakeInbound()
    let handshake = try XCTUnwrap(
        Data(base64Encoded: remoteServiceHandshakeWrapper)
    )
    inbound.append(
        remoteXPCTestFrame(
            type: 0x00,
            streamIdentifier: 1,
            payload: handshake
        )
    )
    return inbound
}
