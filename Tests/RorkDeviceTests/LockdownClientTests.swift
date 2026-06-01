import Foundation
import XCTest
@testable import RorkDevice

final class LockdownClientTests: XCTestCase {
    func testStartSessionParsesSecureSessionRequirement() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "SessionID": "session-1",
            "EnableSessionSSL": true,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")
        let pairing = try PairingRecord.parse(pairingRecordData())

        let session = try await client.startSession(pairingRecord: pairing)

        XCTAssertEqual(session.sessionID, "session-1")
        XCTAssertTrue(session.requiresSecureConnection)

        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Request"] as? String, "StartSession")
        XCTAssertEqual(request["HostID"] as? String, "host-1")
        XCTAssertEqual(request["SystemBUID"] as? String, "system-1")
    }

    func testGetValueSendsLockdownRequestAndReturnsValue() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Value": [
                "DeviceName": "Test Phone",
                "ProductVersion": "18.0",
            ],
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")

        let value = try await client.getValue(domain: nil, key: nil)

        let dictionary = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(dictionary["DeviceName"] as? String, "Test Phone")

        let sentLength = try connection.sent[0].bigEndianInteger(at: 0, as: UInt32.self)
        let sentPayload = connection.sent[0].dropFirst(4)
        XCTAssertEqual(Int(sentLength), sentPayload.count)
        let request = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(sentPayload), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(request["Request"] as? String, "GetValue")
        XCTAssertEqual(request["Label"] as? String, "tests")
    }

    func testStartServiceParsesServiceDescriptor() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Port": 12345,
            "EnableServiceSSL": true,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)

        let service = try await client.startService("com.apple.afc")

        XCTAssertEqual(service.name, "com.apple.afc")
        XCTAssertEqual(service.port, 12345)
        XCTAssertTrue(service.requiresSecureConnection)
    }

    func testLockdownErrorResponseThrowsStructuredError() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Failure",
            "Error": "InvalidHostID",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.getValue(domain: nil, key: nil) }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .lockdown("GetValue failed: InvalidHostID"))
        }
    }
}

private func pairingRecordData() throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: [
            "UDID": "device-1",
            "HostID": "host-1",
            "SystemBUID": "system-1",
        ],
        format: .xml,
        options: 0
    )
}

private func decodedSentPlist(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}
