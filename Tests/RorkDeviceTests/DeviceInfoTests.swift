import XCTest
@testable import RorkDevice

final class DeviceInfoTests: XCTestCase {
    func testExtractsCommonLockdownFieldsAndScalarRawValues() {
        let info = DeviceInfo(values: [
            "UniqueDeviceID": "device-1",
            "DeviceName": "Test Phone",
            "ProductType": "iPhone16,2",
            "ProductVersion": "18.0",
            "BuildVersion": "22A000",
            "Number": NSNumber(value: 7),
            "Nested": ["ignored": true],
        ])

        XCTAssertEqual(info.uniqueDeviceID, "device-1")
        XCTAssertEqual(info.deviceName, "Test Phone")
        XCTAssertEqual(info.productType, "iPhone16,2")
        XCTAssertEqual(info.productVersion, "18.0")
        XCTAssertEqual(info.buildVersion, "22A000")
        XCTAssertEqual(info.rawValues["Number"], "7")
        XCTAssertNil(info.rawValues["Nested"])
    }

    func testInstalledApplicationExtractsCommonFieldsAndRawValues() {
        let app = InstalledApplication(values: [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleDisplayName": "Example",
            "CFBundleExecutable": "ExampleExecutable",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "ApplicationType": "User",
            "Number": NSNumber(value: 7),
        ])

        XCTAssertEqual(app.bundleIdentifier, "com.example.app")
        XCTAssertEqual(app.displayName, "Example")
        XCTAssertEqual(app.executableName, "ExampleExecutable")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.buildVersion, "45")
        XCTAssertEqual(app.applicationType, "User")
        XCTAssertEqual(app.rawValues["Number"], DiagnosticValue(description: "7"))
    }
}
