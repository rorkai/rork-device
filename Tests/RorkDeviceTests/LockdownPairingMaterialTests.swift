import Foundation
import NIOSSL
import XCTest
import X509
import _CryptoExtras
@testable import RorkDevice

final class LockdownPairingMaterialTests: XCTestCase {
    func testCreatesCompletePortablePairingMaterial() throws {
        let record = try LockdownPairingMaterial.generate(
            deviceIdentifier: "device-1",
            systemBUID: "system-1",
            devicePublicKey: testDevicePublicKeyPEM,
            wiFiMACAddress: "00:11:22:33:44:55",
            validFrom: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(record.udid, "device-1")
        XCTAssertEqual(record.systemBUID, "system-1")
        XCTAssertEqual(
            record.wiFiMACAddress,
            "00:11:22:33:44:55"
        )
        XCTAssertFalse(record.hostID.isEmpty)
        XCTAssertTrue(record.hasSecureSessionMaterial)
        XCTAssertNotNil(record.rootPrivateKey)
        XCTAssertNil(record.escrowBag)

        _ = try NIOSSLCertificate(
            bytes: Array(try XCTUnwrap(record.rootCertificate)),
            format: .pem
        )
        _ = try NIOSSLCertificate(
            bytes: Array(try XCTUnwrap(record.hostCertificate)),
            format: .pem
        )
        _ = try NIOSSLCertificate(
            bytes: Array(try XCTUnwrap(record.deviceCertificate)),
            format: .pem
        )
        _ = try NIOSSLPrivateKey(
            bytes: Array(try XCTUnwrap(record.rootPrivateKey)),
            format: .pem
        )
        _ = try NIOSSLPrivateKey(
            bytes: Array(try XCTUnwrap(record.hostPrivateKey)),
            format: .pem
        )

        let rootCertificate = try certificate(
            from: try XCTUnwrap(record.rootCertificate)
        )
        let hostCertificate = try certificate(
            from: try XCTUnwrap(record.hostCertificate)
        )
        let deviceCertificate = try certificate(
            from: try XCTUnwrap(record.deviceCertificate)
        )
        let rootPrivateKey = try _RSA.Signing.PrivateKey(
            pemRepresentation: String(
                decoding: try XCTUnwrap(record.rootPrivateKey),
                as: UTF8.self
            )
        )
        let hostPrivateKey = try _RSA.Signing.PrivateKey(
            pemRepresentation: String(
                decoding: try XCTUnwrap(record.hostPrivateKey),
                as: UTF8.self
            )
        )
        let devicePublicKey = try _RSA.Signing.PublicKey(
            pemRepresentation: String(
                decoding: testDevicePublicKeyPEM,
                as: UTF8.self
            )
        )

        XCTAssertEqual(
            rootCertificate.publicKey,
            Certificate.PublicKey(rootPrivateKey.publicKey)
        )
        XCTAssertEqual(
            hostCertificate.publicKey,
            Certificate.PublicKey(hostPrivateKey.publicKey)
        )
        XCTAssertEqual(
            deviceCertificate.publicKey,
            Certificate.PublicKey(devicePublicKey)
        )
        XCTAssertTrue(
            rootCertificate.publicKey.isValidSignature(
                rootCertificate.signature,
                for: rootCertificate
            )
        )
        XCTAssertTrue(
            rootCertificate.publicKey.isValidSignature(
                hostCertificate.signature,
                for: hostCertificate
            )
        )
        XCTAssertTrue(
            rootCertificate.publicKey.isValidSignature(
                deviceCertificate.signature,
                for: deviceCertificate
            )
        )
    }

    func testAddingEscrowBagPreservesGeneratedIdentity() throws {
        let candidate = try LockdownPairingMaterial.generate(
            deviceIdentifier: "device-1",
            systemBUID: "system-1",
            devicePublicKey: testDevicePublicKeyPEM,
            wiFiMACAddress: "00:11:22:33:44:55"
        )

        let completed = try candidate.addingEscrowBag(Data([1, 2, 3]))

        XCTAssertEqual(completed.hostID, candidate.hostID)
        XCTAssertEqual(
            completed.hostPrivateKey,
            candidate.hostPrivateKey
        )
        XCTAssertEqual(completed.escrowBag, Data([1, 2, 3]))
    }

    /// Parses one generated PEM certificate for structural and signature checks.
    private func certificate(from data: Data) throws -> Certificate {
        try Certificate(
            pemEncoded: String(decoding: data, as: UTF8.self)
        )
    }
}
