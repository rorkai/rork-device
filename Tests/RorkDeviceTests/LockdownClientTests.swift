import Foundation
import XCTest
@testable import RorkDevice

final class LockdownClientTests: XCTestCase {
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
}
