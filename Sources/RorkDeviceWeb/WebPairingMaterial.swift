#if canImport(JavaScriptKit)
import Foundation
import JavaScriptFoundationCompat
import JavaScriptKit
import RorkDevice

/// Generates Lockdown pairing credentials with the browser Web Crypto API.
///
/// JavaScript key handles never leave the main actor. The generated private
/// keys and certificates are exported immediately into the caller-owned
/// `PairingRecord`, which is the only persistence format exposed by the web
/// product.
@MainActor
enum WebPairingMaterial {
    /// Lifetime used by host pairing certificates.
    private static let certificateLifetime: TimeInterval =
        10 * 365 * 24 * 60 * 60

    /// Creates one candidate host identity for an unpaired device.
    ///
    /// A single root signs both the host and device leaf certificates. The
    /// candidate intentionally has no escrow bag; Lockdown adds it after the
    /// user accepts the Trust dialog.
    static func candidate(
        for information: DevicePairingInformation,
        systemBUID: String,
        validFrom: Date = Date()
    ) async throws -> PairingRecord {
        let deviceIdentifier = try validated(
            information.deviceIdentifier,
            field: "device identifier"
        )
        let systemBUID = try validated(
            systemBUID,
            field: "system BUID"
        )
        let wiFiMACAddress = try validated(
            information.wiFiMACAddress,
            field: "Wi-Fi address"
        )
        let deviceKey = try PairingCertificateBuilder.publicKey(
            fromPEM: information.devicePublicKey
        )
        let cryptography = try WebCryptography()
        let rootKey = try await cryptography.generateRSAKeyPair()
        let hostKey = try await cryptography.generateRSAKeyPair()
        let validUntil = validFrom.addingTimeInterval(
            certificateLifetime
        )

        let rootCertificate = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: rootKey.publicKeyInfo,
            subjectKeyIdentifier: try await cryptography.sha1(
                rootKey.subjectPublicKey
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .certificateAuthority,
            signer: { data in
                try await cryptography.signSHA1(
                    data,
                    using: rootKey.privateKey
                )
            }
        )
        let hostCertificate = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: hostKey.publicKeyInfo,
            subjectKeyIdentifier: try await cryptography.sha1(
                hostKey.subjectPublicKey
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .leaf,
            signer: { data in
                try await cryptography.signSHA1(
                    data,
                    using: rootKey.privateKey
                )
            }
        )
        let deviceCertificate = try await PairingCertificateBuilder.certificate(
            publicKeyInfo: deviceKey.subjectPublicKeyInfo,
            subjectKeyIdentifier: try await cryptography.sha1(
                deviceKey.subjectPublicKey
            ),
            validFrom: validFrom,
            validUntil: validUntil,
            role: .leaf,
            signer: { data in
                try await cryptography.signSHA1(
                    data,
                    using: rootKey.privateKey
                )
            }
        )

        return try PairingRecord.candidate(
            deviceIdentifier: deviceIdentifier,
            hostID: UUID().uuidString.uppercased(),
            systemBUID: systemBUID,
            deviceCertificate: PairingCertificateBuilder.pem(
                discriminator: "CERTIFICATE",
                derBytes: deviceCertificate
            ),
            hostCertificate: PairingCertificateBuilder.pem(
                discriminator: "CERTIFICATE",
                derBytes: hostCertificate
            ),
            hostPrivateKey: PairingCertificateBuilder.pem(
                discriminator: "PRIVATE KEY",
                derBytes: hostKey.privateKeyInfo
            ),
            rootCertificate: PairingCertificateBuilder.pem(
                discriminator: "CERTIFICATE",
                derBytes: rootCertificate
            ),
            rootPrivateKey: PairingCertificateBuilder.pem(
                discriminator: "PRIVATE KEY",
                derBytes: rootKey.privateKeyInfo
            ),
            wiFiMACAddress: wiFiMACAddress
        )
    }

    /// Normalizes one required textual identity field.
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

/// Browser RSA operations needed to construct a Lockdown host identity.
@MainActor
private struct WebCryptography {
    /// `SubtleCrypto` object provided by a secure browser context.
    private let subtleCrypto: JSObject

    /// Resolves the browser cryptography implementation.
    init() throws {
        guard
            let subtleCrypto =
                JSObject.global.crypto.object?.subtle.object
        else {
            throw WebUSBError.unavailable
        }
        self.subtleCrypto = subtleCrypto
    }

    /// Generates one extractable 2048-bit RSA signing key pair.
    func generateRSAKeyPair() async throws -> RSAKeyPair {
        let algorithm = JSObject()
        algorithm["name"] = "RSASSA-PKCS1-v1_5"
        algorithm["modulusLength"] = 2_048
        algorithm["publicExponent"] =
            JSTypedArray<UInt8>(
                [0x01, 0x00, 0x01]
            ).jsValue
        algorithm["hash"] = "SHA-1"
        let usages = JSObject.global.Array.function!.new(
            "sign",
            "verify"
        )
        let generated = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "generateKey",
                on: subtleCrypto,
                arguments: [
                    algorithm,
                    true,
                    usages,
                ]
            ),
            operation: "Generating a pairing key"
        )
        guard let keyPair = generated.object,
            let publicKey = keyPair.publicKey.object,
            let privateKey = keyPair.privateKey.object
        else {
            throw WebUSBError.invalidBrowserResponse(
                "generateKey did not return an RSA CryptoKeyPair."
            )
        }

        let publicKeyInfo = try await export(
            "spki",
            key: publicKey
        )
        let privateKeyInfo = try await export(
            "pkcs8",
            key: privateKey
        )
        let publicKeyMaterial = try PairingCertificateBuilder.publicKey(
            fromPEM: PairingCertificateBuilder.pem(
                discriminator: "PUBLIC KEY",
                derBytes: publicKeyInfo
            )
        )
        return RSAKeyPair(
            privateKey: privateKey,
            publicKeyInfo: publicKeyInfo,
            subjectPublicKey: publicKeyMaterial.subjectPublicKey,
            privateKeyInfo: privateKeyInfo
        )
    }

    /// Computes the RFC 5280 subject-key identifier digest.
    func sha1(_ data: Data) async throws -> Data {
        let result = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "digest",
                on: subtleCrypto,
                arguments: [
                    "SHA-1",
                    data.jsTypedArray,
                ]
            ),
            operation: "Hashing a pairing public key"
        )
        return try dataFromJavaScriptArrayBuffer(
            result,
            field: "SubtleCrypto.digest result"
        )
    }

    /// Signs certificate TBS bytes with RSA PKCS#1 v1.5 and SHA-1.
    func signSHA1(
        _ data: Data,
        using privateKey: JSObject
    ) async throws -> Data {
        let algorithm = JSObject()
        algorithm["name"] = "RSASSA-PKCS1-v1_5"
        let result = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "sign",
                on: subtleCrypto,
                arguments: [
                    algorithm,
                    privateKey,
                    data.jsTypedArray,
                ]
            ),
            operation: "Signing a pairing certificate"
        )
        return try dataFromJavaScriptArrayBuffer(
            result,
            field: "SubtleCrypto.sign result"
        )
    }

    /// Exports one browser key into a standard DER representation.
    private func export(
        _ format: String,
        key: JSObject
    ) async throws -> Data {
        let result = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "exportKey",
                on: subtleCrypto,
                arguments: [
                    format,
                    key,
                ]
            ),
            operation: "Exporting a pairing key"
        )
        return try dataFromJavaScriptArrayBuffer(
            result,
            field: "SubtleCrypto.exportKey result"
        )
    }

    /// Extractable key bytes plus the actor-confined private key handle.
    struct RSAKeyPair {
        let privateKey: JSObject
        let publicKeyInfo: Data
        let subjectPublicKey: Data
        let privateKeyInfo: Data
    }
}
#endif
