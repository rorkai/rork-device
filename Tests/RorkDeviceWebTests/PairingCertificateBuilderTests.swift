import CryptoExtras
import Foundation
import X509
import XCTest

@testable import RorkDeviceWeb

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class PairingCertificateBuilderTests: XCTestCase {
    func testBuildsVerifiableLockdownCertificateHierarchy() async throws {
        let rootKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let hostKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let deviceKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let validFrom = Date(timeIntervalSince1970: 1_700_000_000)
        let validUntil = validFrom.addingTimeInterval(
            10 * 365 * 24 * 60 * 60
        )
        let signer = rsaSHA1Signer(rootKey)

        let rootDER = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: rootKey.publicKey.derRepresentation,
            subjectKeyIdentifier: Data(
                Insecure.SHA1.hash(
                    data: rootKey.publicKey.pkcs1DERRepresentation
                )
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .certificateAuthority,
            signer: signer
        )
        let hostDER = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: hostKey.publicKey.derRepresentation,
            subjectKeyIdentifier: Data(
                Insecure.SHA1.hash(
                    data: hostKey.publicKey.pkcs1DERRepresentation
                )
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .leaf,
            signer: signer
        )
        let deviceDER = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: deviceKey.publicKey.derRepresentation,
            subjectKeyIdentifier: Data(
                Insecure.SHA1.hash(
                    data: deviceKey.publicKey.pkcs1DERRepresentation
                )
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .leaf,
            signer: signer
        )

        let rootCertificate = try Certificate(derEncoded: Array(rootDER))
        let hostCertificate = try Certificate(derEncoded: Array(hostDER))
        let deviceCertificate = try Certificate(
            derEncoded: Array(deviceDER)
        )

        XCTAssertEqual(
            try rootCertificate.extensions.basicConstraints,
            BasicConstraints.isCertificateAuthority(maxPathLength: nil)
        )
        XCTAssertTrue(
            try XCTUnwrap(rootCertificate.extensions.keyUsage).keyCertSign
        )
        XCTAssertEqual(
            try hostCertificate.extensions.basicConstraints,
            BasicConstraints.notCertificateAuthority
        )
        XCTAssertTrue(
            try XCTUnwrap(hostCertificate.extensions.keyUsage)
                .digitalSignature
        )
        XCTAssertTrue(
            try XCTUnwrap(hostCertificate.extensions.keyUsage)
                .keyEncipherment
        )
        XCTAssertEqual(
            try deviceCertificate.extensions.basicConstraints,
            BasicConstraints.notCertificateAuthority
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

    func testConvertsPKCS1PublicKeyPEMToSubjectPublicKeyInfo() throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048).publicKey

        let publicKey = try PairingCertificateBuilder.publicKey(
            fromPEM: Data(key.pkcs1PEMRepresentation.utf8)
        )

        XCTAssertEqual(publicKey.subjectPublicKey, key.pkcs1DERRepresentation)
        XCTAssertNoThrow(
            try Certificate.PublicKey(
                derEncoded: Array(publicKey.subjectPublicKeyInfo)
            )
        )
    }

    func testPEMArmorIsNewlineTerminated() {
        let data = PairingCertificateBuilder.pem(
            discriminator: "CERTIFICATE",
            derBytes: Data([0x01, 0x02, 0x03])
        )

        XCTAssertEqual(data.last, 0x0A)
    }

    func testRejectsUnsupportedPublicKeyPEM() {
        let pem = Data(
            """
            -----BEGIN EC PUBLIC KEY-----
            AA==
            -----END EC PUBLIC KEY-----
            """.utf8
        )

        XCTAssertThrowsError(
            try PairingCertificateBuilder.publicKey(fromPEM: pem)
        )
    }
}

private func rsaSHA1Signer(
    _ key: _RSA.Signing.PrivateKey
) -> @Sendable (Data) async throws -> Data {
    { data in
        let digest = Insecure.SHA1.hash(data: data)
        return try key.signature(
            for: digest,
            padding: .insecurePKCS1v1_5
        ).rawRepresentation
    }
}
