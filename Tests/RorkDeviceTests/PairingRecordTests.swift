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
        XCTAssertEqual(record.rawValues["UDID"], DiagnosticValue(description: "device-1"))
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
        XCTAssertTrue(record.missingSecureSessionFields.contains("DeviceCertificate"))
        XCTAssertTrue(record.missingSecureSessionFields.contains("HostCertificate"))
        XCTAssertTrue(record.missingSecureSessionFields.contains("HostPrivateKey"))
        XCTAssertFalse(record.missingSecureSessionFields.contains("EscrowBag"))
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

    func testSerializesPairingRecordWithoutDroppingUnknownValues() throws {
        let sourceValues: [String: Any] = [
            "UDID": "device-1",
            "HostID": "host-1",
            "SystemBUID": "system-1",
            "EscrowBag": Data([1, 2, 3]),
            "WiFiMACAddress": "00:11:22:33:44:55",
            "DeviceName": "Test iPhone",
            "HostAttached": true,
        ]
        let record = try PairingRecord.parse(
            PropertyListSerialization.data(
                fromPropertyList: sourceValues,
                format: .xml,
                options: 0
            )
        )

        let encoded = try record.propertyListData(format: .binary)
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: encoded,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(decoded["UDID"] as? String, "device-1")
        XCTAssertEqual(decoded["EscrowBag"] as? Data, Data([1, 2, 3]))
        XCTAssertEqual(
            decoded["WiFiMACAddress"] as? String,
            "00:11:22:33:44:55"
        )
        XCTAssertEqual(decoded["DeviceName"] as? String, "Test iPhone")
        XCTAssertEqual((decoded["HostAttached"] as? NSNumber)?.boolValue, true)
    }
}
