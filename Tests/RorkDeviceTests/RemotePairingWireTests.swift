import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingWireTests: XCTestCase {
    func testFrameRoundTrip() async throws {
        let message: [String: Any] = [
            "message": [
                "plain": [
                    "_0": [
                        "request": "handshake",
                    ],
                ],
            ],
            "originatedBy": "host",
            "sequenceNumber": 3,
        ]
        let encoded = try RemotePairingFrameCodec.encode(message)
        let connection = FakeConnection(inbound: encoded)

        let decoded = try await RemotePairingFrameCodec.receive(from: connection)

        XCTAssertEqual(decoded["originatedBy"] as? String, "host")
        XCTAssertEqual(decoded["sequenceNumber"] as? Int, 3)
        XCTAssertEqual(encoded.prefix(RemotePairingFrameCodec.magic.count), RemotePairingFrameCodec.magic)
    }

    func testFrameRejectsWrongMagic() async throws {
        var encoded = try RemotePairingFrameCodec.encode(["message": "value"])
        encoded.replaceSubrange(0..<RemotePairingFrameCodec.magic.count, with: Data(repeating: 0, count: 9))
        let connection = FakeConnection(inbound: encoded)

        do {
            _ = try await RemotePairingFrameCodec.receive(from: connection)
            XCTFail("Expected invalid frame magic to fail.")
        } catch {
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("Remote pairing frame has an invalid magic prefix.")
            )
        }
    }

    func testTLV8SplitsAndCoalescesLargeValues() throws {
        let payload = Data((0..<600).map { UInt8($0 % 251) })

        let encoded = TLV8.encode([
            TLV8Field(type: 0x03, value: payload),
            TLV8Field(type: 0x06, value: Data([0x03])),
        ])
        let decoded = try TLV8.decode(encoded)

        XCTAssertEqual(decoded.value(for: 0x03), payload)
        XCTAssertEqual(decoded.value(for: 0x06), Data([0x03]))
        XCTAssertEqual(decoded.fields.filter { $0.type == 0x03 }.map(\.value.count), [255, 255, 90])
    }

    func testTLV8EncodesDataWithNonZeroStartIndex() throws {
        let value = Data([0xff, 0x01, 0x02, 0x03]).dropFirst()

        let encoded = TLV8.encode([
            TLV8Field(type: 0x04, value: value),
        ])

        XCTAssertEqual(try TLV8.decode(encoded).value(for: 0x04), Data([0x01, 0x02, 0x03]))
    }

    func testTLV8RejectsTruncatedValue() {
        XCTAssertThrowsError(try TLV8.decode(Data([0x03, 0x02, 0xff]))) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("TLV8 value for type 3 is truncated.")
            )
        }
    }
}
