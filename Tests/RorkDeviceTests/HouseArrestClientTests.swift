import Foundation
import XCTest
@testable import RorkDevice

final class HouseArrestClientTests: XCTestCase {
    func testOpenApplicationContainerVendsDocumentsAndReturnsAFCClient() async throws {
        var inbound = Data()
        inbound.append(try PropertyListMessageFramer.encode(["Status": "Complete"]))
        inbound.append(afcDataResponse(packetNumber: 1, payload: nullTerminated(["Documents"])))
        let connection = FakeConnection(inbound: inbound)
        let client = HouseArrestClient(connection: connection)

        let afc = try await client.openApplicationContainer(
            bundleIdentifier: "com.example.app",
            scope: .documents
        )
        let names = try await afc.directoryContents(at: "/")

        XCTAssertEqual(names, ["Documents"])
        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "VendDocuments")
        XCTAssertEqual(request["Identifier"] as? String, "com.example.app")
    }

    func testOpenApplicationContainerCanRequestFullContainer() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode(["Status": "Complete"]))
        let client = HouseArrestClient(connection: connection)

        _ = try await client.openApplicationContainer(
            bundleIdentifier: "com.example.app",
            scope: .container
        )

        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Command"] as? String, "VendContainer")
    }

    func testOpenApplicationContainerRejectsSecondVendOnSameConnection() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode(["Status": "Complete"]))
        let client = HouseArrestClient(connection: connection)

        _ = try await client.openApplicationContainer(bundleIdentifier: "com.example.app")

        await XCTAssertThrowsErrorAsync({
            _ = try await client.openApplicationContainer(bundleIdentifier: "com.example.other")
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("HouseArrestClient cannot vend more than one container per connection.")
            )
        }
        XCTAssertEqual(connection.sent.count, 1)
    }

    func testOpenApplicationContainerAllowsRetryAfterFailedVend() async throws {
        var inbound = Data()
        inbound.append(try PropertyListMessageFramer.encode(["Error": "Busy"]))
        inbound.append(try PropertyListMessageFramer.encode(["Status": "Complete"]))
        let connection = FakeConnection(inbound: inbound)
        let client = HouseArrestClient(connection: connection)

        await XCTAssertThrowsErrorAsync({
            _ = try await client.openApplicationContainer(bundleIdentifier: "com.example.app")
        }) { _ in }
        _ = try await client.openApplicationContainer(bundleIdentifier: "com.example.app")

        XCTAssertEqual(connection.sent.count, 2)
    }

    func testOpenApplicationContainerThrowsProtocolErrorResponse() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode([
            "Error": "ApplicationLookupFailed",
            "ErrorDescription": "No such application",
        ]))
        let client = HouseArrestClient(connection: connection)

        await XCTAssertThrowsErrorAsync({
            _ = try await client.openApplicationContainer(bundleIdentifier: "com.missing.app")
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("HouseArrest failed: ApplicationLookupFailed: No such application")
            )
        }
    }
}

private func decodedSentPlist(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}

private func afcDataResponse(packetNumber: UInt64, payload: Data) -> Data {
    var data = Data("CFA6LPAA".utf8)
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(packetNumber)
    data.appendLittleEndian(UInt64(2))
    data.append(payload)
    return data
}

private func nullTerminated(_ strings: [String]) -> Data {
    var data = Data()
    for string in strings {
        data.append(contentsOf: string.utf8)
        data.append(0)
    }
    return data
}
