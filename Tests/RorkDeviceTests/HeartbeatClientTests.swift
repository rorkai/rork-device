import Foundation
import XCTest
@testable import RorkDevice

final class HeartbeatClientTests: XCTestCase {
    func testRespondOnceRepliesWithBinaryPolo() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode(["Interval": 2]))
        let client = HeartbeatClient(connection: connection)

        let interval = try await client.respondOnce()

        XCTAssertEqual(interval, 2)
        let reply = try XCTUnwrap(connection.sent.first)
        let payload = try plistPayload(reply)
        XCTAssertTrue(payload.starts(with: Data("bplist".utf8)))
        let dictionary = try XCTUnwrap(PropertyListCodec.decode(payload) as? [String: Any])
        XCTAssertEqual(dictionary["Command"] as? String, "Polo")
    }

    func testRespondOnceThrowsForSleepyTime() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode(["Command": "SleepyTime"]))
        let client = HeartbeatClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.respondOnce() }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .heartbeat("Device reported SleepyTime."))
        }
    }

    func testRespondOnceRejectsMalformedHeartbeat() async throws {
        let connection = FakeConnection(inbound: try PropertyListMessageFramer.encode(["Command": "Unexpected"]))
        let client = HeartbeatClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.respondOnce() }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .heartbeat("Response missing Interval."))
        }
    }
}

private func plistPayload(_ message: Data) throws -> Data {
    let length = try Int(message.bigEndianInteger(at: 0, as: UInt32.self))
    return Data(message.dropFirst(4).prefix(length))
}
