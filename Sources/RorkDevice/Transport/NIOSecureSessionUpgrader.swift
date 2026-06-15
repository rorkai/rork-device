import Foundation
import NIOSSL

/// SwiftNIO SSL backend for Lockdown and device-service connections.
///
/// Lockdown negotiates TLS after a plain-text session or service connection is
/// already open. This upgrader inserts an `NIOSSLClientHandler` into the
/// existing SwiftNIO channel, preserving usbmux forwarding while avoiding the
/// deprecated Secure Transport APIs.
public struct NIOSecureSessionUpgrader: SecureSessionUpgrader {
    /// Creates a SwiftNIO SSL secure-session upgrader.
    public init() {}

    /// Adds client-authenticated TLS to an established SwiftNIO connection.
    ///
    /// The device certificate is pinned byte-for-byte to the pairing record.
    /// The host certificate and private key provide the client identity
    /// expected by Lockdown.
    ///
    /// - Parameters:
    ///   - connection: Plain device connection returned by a built-in SwiftNIO
    ///     transport.
    ///   - pairingRecord: Pairing material for the connected device.
    /// - Returns: The same connection after its channel completes the TLS
    ///   handshake.
    /// - Throws: `RorkDeviceError.secureSessionUnsupported` when the connection
    ///   is not backed by a TLS-upgradable SwiftNIO channel, or a pairing/TLS
    ///   error when credentials or negotiation fail.
    public func upgrade(
        _ connection: DeviceConnection,
        pairingRecord: PairingRecord
    ) async throws -> DeviceConnection {
        let configuration = try NIOSecureSessionConfiguration(
            pairingRecord: pairingRecord
        )
        guard let connection = connection as? NIOSecureSessionConnection else {
            throw RorkDeviceError.secureSessionUnsupported
        }

        try await connection.startSecureSession(using: configuration)
        return connection
    }
}

/// Compatibility name for clients that explicitly selected the former backend.
///
/// The implementation now uses SwiftNIO SSL on every supported platform; the
/// alias preserves source compatibility without retaining Secure Transport.
public typealias AppleSecureSessionUpgrader = NIOSecureSessionUpgrader

/// Connection capability required by the built-in SwiftNIO SSL upgrader.
protocol NIOSecureSessionConnection: DeviceConnection {
    /// Inserts TLS into the existing transport and waits for its handshake.
    func startSecureSession(
        using configuration: NIOSecureSessionConfiguration
    ) async throws
}

/// Parsed TLS context and certificate pin for one pairing record.
struct NIOSecureSessionConfiguration: Sendable {
    /// Reusable BoringSSL context containing the client identity and TLS policy.
    let context: NIOSSLContext

    /// Exact DER bytes expected for the device's leaf certificate.
    let trustedServerCertificate: Data

    /// Parses and validates all pairing material before touching the channel.
    init(pairingRecord: PairingRecord) throws {
        guard let deviceCertificateData = pairingRecord.deviceCertificate else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing DeviceCertificate."
            )
        }
        guard let hostCertificateData = pairingRecord.hostCertificate else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing HostCertificate."
            )
        }
        guard let hostPrivateKeyData = pairingRecord.hostPrivateKey else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing HostPrivateKey."
            )
        }

        let deviceCertificate = try makeCertificate(
            deviceCertificateData,
            name: "DeviceCertificate"
        )
        let hostCertificate = try makeCertificate(
            hostCertificateData,
            name: "HostCertificate"
        )
        let hostPrivateKey = try makePrivateKey(
            hostPrivateKeyData,
            name: "HostPrivateKey"
        )

        var certificateChain: [NIOSSLCertificateSource] = [
            .certificate(hostCertificate),
        ]
        if let rootCertificateData = pairingRecord.rootCertificate {
            certificateChain.append(
                .certificate(
                    try makeCertificate(
                        rootCertificateData,
                        name: "RootCertificate"
                    )
                )
            )
        }

        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv1
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates([deviceCertificate])
        configuration.certificateChain = certificateChain
        configuration.privateKey = .privateKey(hostPrivateKey)

        do {
            context = try NIOSSLContext(configuration: configuration)
            trustedServerCertificate = Data(
                try deviceCertificate.toDERBytes()
            )
        } catch {
            throw RorkDeviceError.secureSession(
                "Could not configure TLS from the pairing record: \(error)"
            )
        }
    }
}

/// Creates an in-memory certificate from PEM or DER pairing material.
private func makeCertificate(
    _ data: Data,
    name: String
) throws -> NIOSSLCertificate {
    do {
        return try NIOSSLCertificate(
            bytes: Array(data),
            format: serializationFormat(for: data)
        )
    } catch {
        throw RorkDeviceError.secureSession("Could not parse \(name): \(error)")
    }
}

/// Creates an in-memory private key from PEM or DER pairing material.
private func makePrivateKey(
    _ data: Data,
    name: String
) throws -> NIOSSLPrivateKey {
    do {
        return try NIOSSLPrivateKey(
            bytes: Array(data),
            format: serializationFormat(for: data)
        )
    } catch {
        throw RorkDeviceError.secureSession("Could not parse \(name): \(error)")
    }
}

/// Detects PEM armor while treating every other pairing payload as DER.
private func serializationFormat(
    for data: Data
) -> NIOSSLSerializationFormats {
    guard let prefix = String(
        data: data.prefix(64),
        encoding: .utf8
    ) else {
        return .der
    }
    return prefix.contains("-----BEGIN ") ? .pem : .der
}
