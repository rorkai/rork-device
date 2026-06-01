import Foundation
import XCTest
@testable import RorkDevice

final class PairingRecordTests: XCTestCase {
    func testParsesPairingRecord() throws {
        let plist: [String: Any] = [
            "UDID": "device-1",
            "HostID": "host-1",
            "SystemBUID": "system-1",
            "DeviceCertificate": Data([1, 2, 3]),
            "HostCertificate": Data([4]),
            "HostPrivateKey": Data([5]),
            "RootCertificate": Data([6]),
            "RootPrivateKey": Data([7]),
            "EscrowBag": Data([8]),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let record = try PairingRecord.parse(data)

        XCTAssertEqual(record.udid, "device-1")
        XCTAssertEqual(record.hostID, "host-1")
        XCTAssertEqual(record.systemBUID, "system-1")
        XCTAssertTrue(record.hasSecureSessionMaterial)
        XCTAssertEqual(record.missingSecureSessionFields, [])
    }

    func testReportsMissingSecureSessionFields() throws {
        let plist: [String: Any] = [
            "UDID": "device-1",
            "HostID": "host-1",
            "SystemBUID": "system-1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let record = try PairingRecord.parse(data)

        XCTAssertFalse(record.hasSecureSessionMaterial)
        XCTAssertTrue(record.missingSecureSessionFields.contains("HostPrivateKey"))
        XCTAssertTrue(record.missingSecureSessionFields.contains("EscrowBag"))
    }
}
