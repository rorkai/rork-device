import Foundation
@testable import RorkDevice
import XCTest

final class CompanionProxyClientTests: XCTestCase {
    func testPairedDeviceIdentifiersUsesRegistryCommand() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-2", "WATCH-1"],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let identifiers = try await client.pairedDeviceIdentifiers()

        XCTAssertEqual(identifiers, ["WATCH-2", "WATCH-1"])
        let request = try await capturedRequest(from: connection)
        XCTAssertEqual(request["Command"] as? String, "GetDeviceRegistry")
    }

    func testValueUsesRegistryLookupKeys() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "DeviceName": "My Watch",
                ],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let value = try await client.value(
            forKey: "DeviceName",
            on: "WATCH-1"
        )

        XCTAssertEqual(value as? String, "My Watch")
        let request = try await capturedRequest(from: connection)
        XCTAssertEqual(
            request["Command"] as? String,
            "GetValueFromRegistry"
        )
        XCTAssertEqual(
            request["GetValueGizmoUDIDKey"] as? String,
            "WATCH-1"
        )
        XCTAssertEqual(
            request["GetValueKeyKey"] as? String,
            "DeviceName"
        )
    }

    func testValueReturnsNilWhenRegistryOmitsKey() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [:],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let value = try await client.value(
            forKey: "ModelNumber",
            on: "WATCH-1"
        )

        XCTAssertNil(value)
    }

    func testPairedDeviceIdentifiersRejectsMalformedRegistry() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-1", 42],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        do {
            _ = try await client.pairedDeviceIdentifiers()
            XCTFail("Expected malformed registry rejection.")
        } catch let error as RorkDeviceError {
            guard case .protocolViolation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

/// Decodes one captured request through the production framing implementation.
private func capturedRequest(
    from connection: FakeConnection
) async throws -> [String: Any] {
    let data = try XCTUnwrap(connection.sent.first)
    return try await PropertyListMessageFramer.receive(
        from: FakeConnection(inbound: data)
    )
}
