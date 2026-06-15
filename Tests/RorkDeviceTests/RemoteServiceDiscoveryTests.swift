import Foundation
import XCTest
@testable import RorkDevice

final class RemoteServiceDiscoveryTests: XCTestCase {
    func testOpensRemoteXPCAndParsesAdvertisedServices() async throws {
        let connection = FakeConnection(inbound: try XCTUnwrap(Data(base64Encoded: remoteServiceHandshakeWire)))

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
        var inbound = makeHTTP2Frame(type: 0x04, streamID: 0)
        inbound.append(
            makeHTTP2Frame(
                type: 0x00,
                streamID: 1,
                payload: wrapper.prefix(splitIndex)
            )
        )
        inbound.append(
            makeHTTP2Frame(
                type: 0x00,
                streamID: 1,
                payload: wrapper.dropFirst(splitIndex)
            )
        )
        let connection = FakeConnection(inbound: inbound)

        let discovery = try await RemoteServiceDiscoverySession.open(over: connection)

        XCTAssertEqual(discovery.directory.deviceIdentifier, "device-1")
        XCTAssertEqual(discovery.directory.services.count, 2)
    }
}

private let remoteServiceHandshakeWrapper =
    "kguwKQEBAAAcAQAAAAAAAAAAAAAAAAAAQjcTQgUAAAAA8AAADAEAAAMAAABNZXNzYWdlVHlwZQAAkAAACgAAAEhhbmRzaGFrZQAAAFByb3BlcnRpZXMAAADwAAAoAAAAAQAAAFVuaXF1ZURldmljZUlEAAAAkAAACQAAAGRldmljZS0xAAAAAFNlcnZpY2VzAAAAAADwAACYAAAAAgAAAGNvbS5hcHBsZS5hZmMuc2hpbS5yZW1vdGUAAAAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDEAAABjb20uYXBwbGUubW9iaWxlLmluc3RhbGxhdGlvbl9wcm94eS5zaGltLnJlbW90ZQAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDIAAAA="

private let remoteServiceHandshakeWire =
    "AAAGBAAAAAAAAAQAEAAAAAE0AAAAAAABkguwKQEBAAAcAQAAAAAAAAAAAAAAAAAAQjcTQgUAAAAA8AAADAEAAAMAAABNZXNzYWdlVHlwZQAAkAAACgAAAEhhbmRzaGFrZQAAAFByb3BlcnRpZXMAAADwAAAoAAAAAQAAAFVuaXF1ZURldmljZUlEAAAAkAAACQAAAGRldmljZS0xAAAAAFNlcnZpY2VzAAAAAADwAACYAAAAAgAAAGNvbS5hcHBsZS5hZmMuc2hpbS5yZW1vdGUAAAAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDEAAABjb20uYXBwbGUubW9iaWxlLmluc3RhbGxhdGlvbl9wcm94eS5zaGltLnJlbW90ZQAA8AAAHAAAAAEAAABQb3J0AAAAAACQAAAGAAAANTEwMDIAAAA="

private func makeHTTP2Frame(
    type: UInt8,
    flags: UInt8 = 0,
    streamID: UInt32,
    payload: some DataProtocol = Data()
) -> Data {
    let payload = Data(payload)
    var frame = Data([
        UInt8((payload.count >> 16) & 0xff),
        UInt8((payload.count >> 8) & 0xff),
        UInt8(payload.count & 0xff),
        type,
        flags,
    ])
    frame.appendBigEndian(streamID)
    frame.append(payload)
    return frame
}
