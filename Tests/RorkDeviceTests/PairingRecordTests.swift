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

    func testRejectsMissingRequiredFields() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["UDID": "device-1", "SystemBUID": "system-1"],
            format: .xml,
            options: 0
        )

        XCTAssertThrowsError(try PairingRecord.parse(data)) { error in
            XCTAssertEqual(error as? RorkDeviceError, .invalidPairingRecord("Missing HostID."))
        }
    }

    func testTrimsRequiredStringFields() throws {
        let plist: [String: Any] = [
            "UDID": " device-1 ",
            "HostID": " host-1\n",
            "SystemBUID": "\tsystem-1 ",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let record = try PairingRecord.parse(data)

        XCTAssertEqual(record.udid, "device-1")
        XCTAssertEqual(record.hostID, "host-1")
        XCTAssertEqual(record.systemBUID, "system-1")
    }

    func testLoadsSanitizedPairingRecordFixtures() throws {
        for name in ["macos", "linux"] {
            let url = try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "plist"
                )
            )
            let record = try PairingRecord.load(from: url)

            XCTAssertFalse(record.udid.isEmpty)
            XCTAssertFalse(record.hostID.isEmpty)
            XCTAssertFalse(record.systemBUID.isEmpty)
            XCTAssertTrue(record.hasSecureSessionMaterial)
        }
    }
}
