import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingOPACKEncoderTests: XCTestCase {
    func testEncodesStringAndDataDictionaryDeterministically() throws {
        let encoded = try RemotePairingOPACKEncoder.encode([
            "b": Data([0x01, 0x02]),
            "a": "x",
        ])

        XCTAssertEqual(
            encoded,
            Data([0xe2, 0x41, 0x61, 0x41, 0x78, 0x41, 0x62, 0x72, 0x01, 0x02])
        )
    }
}
