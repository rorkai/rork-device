import Foundation
import XCTest
@testable import RorkDevice

final class DataEndianTests: XCTestCase {
    func testAppendsAndReadsEndianIntegers() throws {
        var data = Data()
        data.appendBigEndian(UInt16(0x1234))
        data.appendLittleEndian(UInt32(0x89ABCDEF))

        XCTAssertEqual(try data.bigEndianInteger(at: 0, as: UInt16.self), 0x1234)
        XCTAssertEqual(try data.littleEndianInteger(at: 2, as: UInt32.self), 0x89ABCDEF)
    }

    func testIntegerReadChecksBounds() {
        XCTAssertThrowsError(try Data([1, 2]).littleEndianInteger(at: 1, as: UInt32.self)) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("Packet is too short for UInt32 at offset 1.")
            )
        }
    }
}
