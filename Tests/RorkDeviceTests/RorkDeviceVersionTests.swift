import XCTest
@testable import RorkDevice

final class RorkDeviceVersionTests: XCTestCase {
    func testVersionIsLoadedFromPackageResource() {
        XCTAssertFalse(RorkDevice.version.isEmpty)
        XCTAssertNotEqual(RorkDevice.version, "unknown")
        XCTAssertTrue(RorkDevice.version.split(separator: ".").count >= 3)
    }
}
