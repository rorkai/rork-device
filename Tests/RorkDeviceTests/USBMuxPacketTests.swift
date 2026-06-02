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

    func testDecodeRejectsWrongHeaderLength() {
        XCTAssertThrowsError(try USBMuxPacket.decode(header: Data([0]), payload: Data())) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("Invalid usbmux header length 1."))
        }
    }

    func testDecodeRejectsPayloadLengthMismatch() throws {
        var header = Data()
        header.appendLittleEndian(UInt32(99))
        header.appendLittleEndian(UInt32(1))
        header.appendLittleEndian(UInt32(8))
        header.appendLittleEndian(UInt32(42))

        XCTAssertThrowsError(try USBMuxPacket.decode(header: header, payload: Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("usbmux payload length mismatch."))
        }
    }
}
