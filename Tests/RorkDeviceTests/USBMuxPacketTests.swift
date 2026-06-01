import Foundation
import XCTest
@testable import RorkDevice

final class USBMuxPacketTests: XCTestCase {
    func testEncodesAndDecodesPlistPacketHeader() throws {
        let payload = Data([1, 2, 3])
        let packet = USBMuxPacket(tag: 42, payload: payload)
        let encoded = try packet.encoded()

        XCTAssertEqual(try encoded.littleEndianInteger(at: 0, as: UInt32.self), UInt32(19))
        XCTAssertEqual(try encoded.littleEndianInteger(at: 4, as: UInt32.self), UInt32(1))
        XCTAssertEqual(try encoded.littleEndianInteger(at: 8, as: UInt32.self), UInt32(8))
        XCTAssertEqual(try encoded.littleEndianInteger(at: 12, as: UInt32.self), UInt32(42))

        let decoded = try USBMuxPacket.decode(
            header: encoded.prefix(16),
            payload: encoded.dropFirst(16)
        )
        XCTAssertEqual(decoded.tag, 42)
        XCTAssertEqual(decoded.payload, payload)
    }
}
