#if canImport(CryptoExtras) && canImport(X509)
import CryptoExtras
import Foundation
import X509

extension PairingRecord {
    /// Creates host-owned pairing material for an unpaired device.
    ///
    /// The returned candidate contains the certificate chain and private keys
    /// needed by Lockdown but no escrow bag. Submit the candidate through
    /// `DeviceClient.pair(using:over:trustTimeout:retryInterval:onProgress:)`
    /// and persist the accepted record returned by that operation.
    ///
    /// - Parameters:
    ///   - information: Public identity fields read from the target device.
    ///   - systemBUID: Stable host identifier associated with the application
    ///     storing this pairing record.
    ///   - validFrom: Beginning of the generated certificate validity period.
    ///     The default is appropriate for production; the parameter also makes
    ///     deterministic certificate tests possible.
    /// - Returns: Candidate pairing material ready for a Lockdown `Pair`
    ///   request.
    /// - Throws: `RorkDeviceError.invalidInput` for malformed identity fields,
    ///   or a certificate-generation error.
    public static func candidate(
        for information: DevicePairingInformation,
        systemBUID: String,
        validFrom: Date = Date()
    ) throws -> PairingRecord {
        try LockdownPairingMaterial.generate(
            deviceIdentifier: information.deviceIdentifier,
            systemBUID: systemBUID,
            devicePublicKey: information.devicePublicKey,
            wiFiMACAddress: information.wiFiMACAddress,
            validFrom: validFrom
        )
    }
}

/// Generates the certificate chain and private keys used by Lockdown pairing.
///
/// Lockdown expects a host-owned root certificate, a host leaf certificate,
/// and a device leaf certificate derived from the public key reported by the
/// connected device. The root signs both leaf certificates. Private keys remain
/// in the host pairing record and are never included in the `Pair` request.
enum LockdownPairingMaterial {
    /// Lifetime used by the certificate hierarchy generated for host pairing.
    ///
    /// Lockdown pairing identities are intended to survive across many device
    /// sessions. A ten-year validity window matches that long-lived identity
    /// model without making the certificates effectively unbounded.
    private static let certificateLifetime: TimeInterval =
        10 * 365 * 24 * 60 * 60

    /// Creates candidate pairing material for one physical device.
    ///
    /// The returned record intentionally has no escrow bag. Lockdown supplies
    /// that value only after the user accepts the Trust dialog, at which point
    /// the completed record can be saved through usbmux.
    ///
    /// - Parameters:
    ///   - deviceIdentifier: UDID used as the usbmux pairing-record key.
    ///   - systemBUID: Host identifier maintained by the local usbmux daemon.
    ///   - devicePublicKey: PEM-encoded RSA key read from Lockdown.
    ///   - wiFiMACAddress: Wi-Fi address reported by Lockdown for the record.
    ///   - validFrom: Certificate validity start, injectable for deterministic
    ///     tests.
    /// - Returns: Complete host credentials ready for a Lockdown `Pair`
    ///   request.
    static func generate(
        deviceIdentifier: String,
        systemBUID: String,
        devicePublicKey: Data,
        wiFiMACAddress: String,
        validFrom: Date = Date()
    ) throws -> PairingRecord {
        let deviceIdentifier = try validated(
            deviceIdentifier,
            field: "device identifier"
        )
        let systemBUID = try validated(systemBUID, field: "system BUID")
        let wiFiMACAddress = try validated(
            wiFiMACAddress,
            field: "Wi-Fi address"
        )
        guard !devicePublicKey.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Lockdown device public key is empty."
            )
        }

        guard
            let deviceKeyPEM = String(
                bytes: devicePublicKey,
                encoding: .utf8
            )
        else {
            throw RorkDeviceError.invalidInput(
                "Lockdown device public key is not valid UTF-8 PEM."
            )
        }
        let deviceKey = try _RSA.Signing.PublicKey(
            pemRepresentation: deviceKeyPEM
        )
        let rootKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let hostKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let name = DistinguishedName()
        let validUntil = validFrom.addingTimeInterval(certificateLifetime)

        let rootPublicKey = Certificate.PublicKey(rootKey.publicKey)
        let rootCertificate = try Certificate(
            version: .v3,
            serialNumber: .init(0),
            publicKey: rootPublicKey,
            notValidBefore: validFrom,
            notValidAfter: validUntil,
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha1WithRSAEncryption,
            extensions: Certificate.Extensions {
                Critical(
                    BasicConstraints.isCertificateAuthority(
                        maxPathLength: nil
                    )
                )
                KeyUsage(keyCertSign: true)
                SubjectKeyIdentifier(hash: rootPublicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey)
        )

        let hostPublicKey = Certificate.PublicKey(hostKey.publicKey)
        let hostCertificate = try makeLeafCertificate(
            publicKey: hostPublicKey,
            issuer: name,
            validFrom: validFrom,
            validUntil: validUntil,
            rootKey: rootKey
        )
        let deviceCertificate = try makeLeafCertificate(
            publicKey: Certificate.PublicKey(deviceKey),
            issuer: name,
            validFrom: validFrom,
            validUntil: validUntil,
            rootKey: rootKey
        )

        return try PairingRecord.candidate(
            deviceIdentifier: deviceIdentifier,
            hostID: UUID().uuidString.uppercased(),
            systemBUID: systemBUID,
            deviceCertificate: try pemData(for: deviceCertificate),
            hostCertificate: try pemData(for: hostCertificate),
            hostPrivateKey: Data(hostKey.pemRepresentation.utf8),
            rootCertificate: try pemData(for: rootCertificate),
            rootPrivateKey: Data(rootKey.pemRepresentation.utf8),
            wiFiMACAddress: wiFiMACAddress
        )
    }

    /// Creates one non-CA certificate signed by the generated pairing root.
    ///
    /// Host and device leaves intentionally share the same constrained key
    /// usage but bind different public keys. Their empty distinguished names
    /// match Lockdown's identity-by-key model rather than introducing host
    /// names that the protocol never validates.
    private static func makeLeafCertificate(
        publicKey: Certificate.PublicKey,
        issuer: DistinguishedName,
        validFrom: Date,
        validUntil: Date,
        rootKey: _RSA.Signing.PrivateKey
    ) throws -> Certificate {
        try Certificate(
            version: .v3,
            serialNumber: .init(0),
            publicKey: publicKey,
            notValidBefore: validFrom,
            notValidAfter: validUntil,
            issuer: issuer,
            subject: DistinguishedName(),
            signatureAlgorithm: .sha1WithRSAEncryption,
            extensions: Certificate.Extensions {
                BasicConstraints.notCertificateAuthority
                KeyUsage(
                    digitalSignature: true,
                    keyEncipherment: true
                )
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey)
        )
    }

    /// Encodes an X.509 certificate in the PEM form expected by Lockdown.
    ///
    /// Pairing property lists store certificates as binary plist data whose
    /// contents are ASCII PEM, not DER bytes.
    private static func pemData(for certificate: Certificate) throws -> Data {
        Data(try certificate.serializeAsPEM().pemString.utf8)
    }

    /// Normalizes a required textual identity field before key generation.
    ///
    /// Returning the trimmed value ensures the validated representation is the
    /// one persisted in the pairing record.
    private static func validated(
        _ value: String,
        field: String
    ) throws -> String {
        let value = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Lockdown pairing \(field) is empty."
            )
        }
        return value
    }
}
#endif
