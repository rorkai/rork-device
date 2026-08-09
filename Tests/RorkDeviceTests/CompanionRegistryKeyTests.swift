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

    /// Keeps numeric and Boolean custom keys concise while preserving type
    /// inference.
    func testScalarFactoriesCreateTypedKeys() {
        let capacity = CompanionRegistryKey<Int>.integer(
            "BatteryCurrentCapacity"
        )
        let charging = CompanionRegistryKey<Bool>.boolean(
            "BatteryIsCharging"
        )

        XCTAssertEqual(capacity.rawValue, "BatteryCurrentCapacity")
        XCTAssertEqual(charging.rawValue, "BatteryIsCharging")
    }
}
