import Foundation
import XCTest
@testable import RorkDevice

final class LockdownClientTests: XCTestCase {
    func testStartSessionParsesSecureSessionRequirement() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "SessionID": "session-1",
            "EnableSessionSSL": true,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")
        let pairing = try PairingRecord.parse(pairingRecordData())

        let session = try await client.startSession(using: pairing)

        XCTAssertEqual(session.sessionID, "session-1")
        XCTAssertTrue(session.requiresSecureConnection)

        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Request"] as? String, "StartSession")
        XCTAssertEqual(request["HostID"] as? String, "host-1")
        XCTAssertEqual(request["SystemBUID"] as? String, "system-1")
    }

    func testValueSendsLockdownRequestAndReturnsValue() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Value": [
                "DeviceName": "Test Phone",
                "ProductVersion": "18.0",
            ],
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")

        let value = try await client.value(domain: nil, key: nil)

        let dictionary = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(dictionary["DeviceName"] as? String, "Test Phone")

        let sentLength = try connection.sent[0].bigEndianInteger(at: 0, as: UInt32.self)
        let sentPayload = connection.sent[0].dropFirst(4)
        XCTAssertEqual(Int(sentLength), sentPayload.count)
        let request = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(sentPayload), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(request["Request"] as? String, "GetValue")
        XCTAssertEqual(request["Label"] as? String, "tests")
    }

    func testDeveloperModeStatusReadsAMFIDomain() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Value": true,
            ])
        )
        let client = LockdownClient(connection: connection)

        let enabled = try await client.developerModeStatus()

        XCTAssertTrue(enabled)
        let request = try XCTUnwrap(
            decodedSentPlist(connection.sent[0])
        )
        XCTAssertEqual(
            request["Domain"] as? String,
            "com.apple.security.mac.amfi"
        )
        XCTAssertEqual(
            request["Key"] as? String,
            "DeveloperModeStatus"
        )
    }

    func testDeveloperModeStatusRejectsNonBooleanValue() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Value": "enabled",
            ])
        )
        let client = LockdownClient(connection: connection)

        await XCTAssertThrowsErrorAsync({
            _ = try await client.developerModeStatus()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Lockdown DeveloperModeStatus was not a Boolean."
                )
            )
        }
    }

    func testDeviceValuesReturnsDefaultLockdownDictionary() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Value": [
                "DeviceName": "Test Phone",
                "ProductVersion": "18.0",
            ],
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")

        let values = try await client.deviceValues()

        XCTAssertEqual(values["DeviceName"] as? String, "Test Phone")
    }

    func testStartServiceParsesServiceDescriptor() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Port": 12345,
            "EnableServiceSSL": true,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)

        let service = try await client.startService("com.apple.afc")

        XCTAssertEqual(service.name, "com.apple.afc")
        XCTAssertEqual(service.port, 12345)
        XCTAssertTrue(service.requiresSecureConnection)
    }

    func testStartServiceCanSendEscrowBag() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Port": 12345,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")
        let escrowBag = Data([1, 2, 3])

        _ = try await client.startService("com.apple.afc", escrowBag: escrowBag)

        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Request"] as? String, "StartService")
        XCTAssertEqual(request["Service"] as? String, "com.apple.afc")
        XCTAssertEqual(request["EscrowBag"] as? Data, escrowBag)
    }

    func testStartServiceRejectsOutOfRangePort() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Success",
            "Port": 70000,
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.startService("com.apple.afc") }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("Lockdown StartService response has invalid Port 70000.")
            )
        }
    }

    func testLockdownErrorResponseThrowsStructuredError() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Result": "Failure",
            "Error": "InvalidHostID",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.value(domain: nil, key: nil) }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .lockdown("GetValue failed: InvalidHostID"))
        }
    }

    func testPairReturnsEscrowBagAndSendsPublicPairingMaterial() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Request": "Pair",
            "EscrowBag": Data([7, 8, 9]),
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection, label: "tests")
        let pairing = try PairingRecord.parse(pairingRecordData())

        let escrowBag = try await client.pair(using: pairing)

        XCTAssertEqual(escrowBag, Data([7, 8, 9]))
        let request = try XCTUnwrap(decodedSentPlist(connection.sent[0]))
        XCTAssertEqual(request["Request"] as? String, "Pair")
        XCTAssertEqual(request["ProtocolVersion"] as? String, "2")
        let options = try XCTUnwrap(
            request["PairingOptions"] as? [String: Any]
        )
        XCTAssertEqual(
            (options["ExtendedPairingErrors"] as? NSNumber)?.boolValue,
            true
        )
        let pairRecord = try XCTUnwrap(
            request["PairRecord"] as? [String: Any]
        )
        XCTAssertEqual(pairRecord["HostID"] as? String, "host-1")
        XCTAssertNil(pairRecord["HostPrivateKey"])
        XCTAssertNil(pairRecord["EscrowBag"])
    }

    func testPairReportsPendingTrustDialog() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Request": "Pair",
            "Error": "PairingDialogResponsePending",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)
        let pairing = try PairingRecord.parse(pairingRecordData())

        await XCTAssertThrowsErrorAsync({
            _ = try await client.pair(using: pairing)
        }) { error in
            XCTAssertEqual(
                error as? LockdownPairingError,
                .userConfirmationRequired
            )
        }
    }

    func testPairReportsUserRejection() async throws {
        let inbound = try PropertyListMessageFramer.encode([
            "Request": "Pair",
            "Error": "UserDeniedPairing",
        ])
        let connection = FakeConnection(inbound: inbound)
        let client = LockdownClient(connection: connection)
        let pairing = try PairingRecord.parse(pairingRecordData())

        await XCTAssertThrowsErrorAsync({
            _ = try await client.pair(using: pairing)
        }) { error in
            XCTAssertEqual(
                error as? LockdownPairingError,
                .userDenied
            )
        }
    }
}

private func pairingRecordData() throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: [
            "UDID": "device-1",
            "HostID": "host-1",
            "SystemBUID": "system-1",
            "DeviceCertificate": Data([1]),
            "HostCertificate": Data([2]),
            "HostPrivateKey": Data([3]),
            "RootCertificate": Data([4]),
            "RootPrivateKey": Data([5]),
        ],
        format: .xml,
        options: 0
    )
}

private func decodedSentPlist(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}
