import Foundation
import XCTest
@testable import RorkDevice

final class PropertyListMessageFramerTests: XCTestCase {
    func testEncodesBigEndianLengthPrefix() throws {
        let encoded = try PropertyListMessageFramer.encode(["Request": "GetValue"])
        let length = try encoded.bigEndianInteger(at: 0, as: UInt32.self)
        XCTAssertEqual(Int(length), encoded.count - 4)
    }

    func testRoundTripsThroughFakeConnection() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Result": "Success", "Value": "ok"])
        let connection = FakeConnection(inbound: inbound)

        try await PropertyListMessageFramer.send(["Request": "GetValue"], to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)

        XCTAssertEqual(response["Result"] as? String, "Success")
        XCTAssertEqual(response["Value"] as? String, "ok")
        XCTAssertEqual(connection.sent.count, 1)
    }

    func testReceiveRejectsNonDictionaryPayload() async throws {
        let payload = try PropertyListCodec.encode(["not", "a", "dictionary"])
        var inbound = Data()
        inbound.appendBigEndian(UInt32(payload.count))
        inbound.append(payload)
        let connection = FakeConnection(inbound: inbound)

        await XCTAssertThrowsErrorAsync({ try await PropertyListMessageFramer.receive(from: connection) }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("Expected property list dictionary response."))
        }
    }

    func testDictionaryHelpersCoerceNSNumberValues() {
        let dictionary: [String: Any] = [
            "String": "value",
            "Bool": NSNumber(value: true),
            "Int": NSNumber(value: 42),
        ]

        XCTAssertEqual(dictionary.string("String"), "value")
        XCTAssertEqual(dictionary.bool("Bool"), true)
        XCTAssertEqual(dictionary.int("Int"), 42)
    }
}
