@testable import RorkDevice
import XCTest

final class CompanionRegistryKeyTests: XCTestCase {
    /// Protects the protocol spelling carried by each known typed key.
    func testKnownStringKeysUseRegistryNames() {
        XCTAssertEqual(
            CompanionRegistryKey<String>.deviceName.rawValue,
            "DeviceName"
        )
        XCTAssertEqual(
            CompanionRegistryKey<String>.modelNumber.rawValue,
            "ModelNumber"
        )
    }

    /// Keeps arbitrary registry extensions available without sacrificing the
    /// expected value type.
    func testStringLiteralCreatesCustomKey() {
        let key: CompanionRegistryKey<String> = "VendorDisplayName"

        XCTAssertEqual(key.rawValue, "VendorDisplayName")
    }
}
