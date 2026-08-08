import Foundation
@testable import RorkDevice
import XCTest

final class LockdownValueKeyTests: XCTestCase {
    /// Protects common default-domain key names and their expected value types.
    func testKnownDefaultDomainKeysUseWireNames() {
        XCTAssertEqual(
            LockdownValueKey<String>.deviceName.rawValue,
            "DeviceName"
        )
        XCTAssertNil(LockdownValueKey<String>.deviceName.domain)
        XCTAssertEqual(
            LockdownValueKey<Data>.devicePublicKey.rawValue,
            "DevicePublicKey"
        )
        XCTAssertEqual(
            LockdownValueKey<String>.wiFiAddress.rawValue,
            "WiFiAddress"
        )
    }

    /// Keeps domain-bearing keys distinct from default Lockdown values.
    func testKnownDomainKeyCarriesItsDomain() {
        let key = LockdownValueKey<Bool>.developerModeStatus

        XCTAssertEqual(key.rawValue, "DeveloperModeStatus")
        XCTAssertEqual(key.domain, "com.apple.security.mac.amfi")
    }

    /// Keeps custom default and named domains available as typed escape hatches.
    func testCreatesCustomKeys() {
        let defaultKey: LockdownValueKey<String> = "CustomValue"
        let domainKey = LockdownValueKey<Int>(
            "CustomCount",
            domain: "com.example.values"
        )
        let defaultDomainCount = LockdownValueKey<Int>("CustomCount")

        XCTAssertEqual(defaultKey.rawValue, "CustomValue")
        XCTAssertNil(defaultKey.domain)
        XCTAssertEqual(domainKey.rawValue, "CustomCount")
        XCTAssertEqual(domainKey.domain, "com.example.values")
        XCTAssertNotEqual(domainKey, defaultDomainCount)
    }
}
