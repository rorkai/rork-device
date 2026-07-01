import CryptoExtras
import Foundation
import NIOSSL
import X509
import XCTest

@testable import RorkDevice

final class LockdownPairingMaterialTests: XCTestCase {
    func testCreatesCompletePortablePairingMaterial() throws {
        let record = try PairingRecord.candidate(
            for: DevicePairingInformation(
                deviceIdentifier: "device-1",
                devicePublicKey: testDevicePublicKeyPEM,
                wiFiMACAddress: "00:11:22:33:44:55"
            ),
            systemBUID: "system-1",
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
            pemRepresentation: try pemString(
                from: try XCTUnwrap(record.rootPrivateKey)
            )
        )
        let hostPrivateKey = try _RSA.Signing.PrivateKey(
            pemRepresentation: try pemString(
                from: try XCTUnwrap(record.hostPrivateKey)
            )
        )
        let devicePublicKey = try _RSA.Signing.PublicKey(
            pemRepresentation: try pemString(
                from: testDevicePublicKeyPEM
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
        // Modern iOS expects SHA-256 pairing certificates; SHA-1 is retired.
        XCTAssertEqual(
            rootCertificate.signatureAlgorithm,
            .sha256WithRSAEncryption
        )
        XCTAssertEqual(
            hostCertificate.signatureAlgorithm,
            .sha256WithRSAEncryption
        )
        XCTAssertEqual(
            deviceCertificate.signatureAlgorithm,
            .sha256WithRSAEncryption
        )
    }

    func testBackdatesCertificateStartForDeviceClockSkew() throws {
        let validFrom = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try LockdownPairingMaterial.generate(
            deviceIdentifier: "device-1",
            systemBUID: "system-1",
            devicePublicKey: testDevicePublicKeyPEM,
            wiFiMACAddress: "00:11:22:33:44:55",
            validFrom: validFrom
        )

        // The start is backdated so a device whose clock trails the host still
        // accepts the saved certificate when it validates the session, while the
        // forward validity stays a full ten years measured from the pairing time
        // rather than from the backdated start.
        let expectedExpiry = validFrom.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        for data in [
            try XCTUnwrap(record.rootCertificate),
            try XCTUnwrap(record.hostCertificate),
            try XCTUnwrap(record.deviceCertificate),
        ] {
            let parsed = try certificate(from: data)
            XCTAssertLessThanOrEqual(
                parsed.notValidBefore,
                validFrom.addingTimeInterval(-3600)
            )
            XCTAssertEqual(
                parsed.notValidAfter.timeIntervalSince1970,
                expectedExpiry.timeIntervalSince1970,
                accuracy: 1
            )
        }
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

    func testRejectsDevicePublicKeyThatIsNotUTF8() {
        XCTAssertThrowsError(
            try LockdownPairingMaterial.generate(
                deviceIdentifier: "device-1",
                systemBUID: "system-1",
                devicePublicKey: Data([0xFF]),
                wiFiMACAddress: "00:11:22:33:44:55"
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Lockdown device public key is not valid UTF-8 PEM."
                )
            )
        }
    }

    /// Parses one generated PEM certificate for structural and signature checks.
    private func certificate(from data: Data) throws -> Certificate {
        try Certificate(
            pemEncoded: pemString(from: data)
        )
    }

    /// Decodes PEM bytes without replacing malformed UTF-8 sequences.
    ///
    /// Pairing tests should fail at the encoding boundary so lossy Unicode
    /// replacement cannot obscure the certificate or key parser's input.
    private func pemString(from data: Data) throws -> String {
        try XCTUnwrap(
            String(bytes: data, encoding: .utf8)
        )
    }
}
