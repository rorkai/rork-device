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
}
