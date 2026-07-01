import Foundation
import NIOSSL

/// Lockdown-specific TLS policies used to isolate device compatibility failures.
///
/// Every profile retains mutual TLS and exact device-certificate pinning. The
/// variants change one negotiation input at a time so diagnostics can identify
/// whether a device rejects the client chain or the offered protocol range.
public enum LockdownTLSProfile: String, CaseIterable, Sendable {
    /// Production configuration: host and root certificates with no TLS maximum.
    case standard

    /// Sends only the host leaf certificate rather than the full client chain.
    case hostCertificateOnly = "host-certificate-only"

    /// Retains the complete client chain while preventing TLS 1.3 negotiation.
    case tls12 = "tls-1.2"
}

/// SwiftNIO SSL backend for Lockdown and device-service connections.
///
/// Lockdown negotiates TLS after a plain-text session or service connection is
/// already open. This upgrader inserts an `NIOSSLClientHandler` into the
/// existing SwiftNIO channel, preserving usbmux forwarding while avoiding the
/// deprecated Secure Transport APIs.
public struct NIOSecureSessionUpgrader: SecureSessionUpgrader {
    /// Lockdown TLS policy applied to each upgraded connection.
    private let profile: LockdownTLSProfile

    /// Creates a SwiftNIO SSL secure-session upgrader with the standard profile.
    public init() {
        self.init(profile: .standard)
    }

    /// Creates a SwiftNIO SSL secure-session upgrader with a diagnostic profile.
    public init(profile: LockdownTLSProfile) {
        self.profile = profile
    }

    /// Adds client-authenticated TLS to an established device connection.
    ///
    /// The device certificate is pinned byte-for-byte to the pairing record.
    /// The host certificate and private key provide the client identity
    /// expected by Lockdown.
    ///
    /// - Parameters:
    ///   - connection: Plain device connection. Built-in SwiftNIO connections
    ///     are upgraded in place; other streaming connections are wrapped by an
    ///     in-memory NIO SSL pipeline.
    ///   - pairingRecord: Pairing material for the connected device.
    /// - Returns: A secure connection after its TLS handshake completes.
    /// - Throws: `RorkDeviceError.secureSessionUnsupported` when the connection
    ///   cannot provide streaming reads, or a pairing/TLS error when credentials
    ///   or negotiation fail.
    public func upgrade(
        _ connection: DeviceConnection,
        pairingRecord: PairingRecord
    ) async throws -> DeviceConnection {
        let configuration = try NIOSecureSessionConfiguration(
            pairingRecord: pairingRecord,
            profile: profile
        )
        if let connection = connection as? NIOSecureSessionConnection {
            try await connection.startSecureSession(using: configuration)
            return connection
        }

        guard
            let streamingConnection =
                connection as? any StreamingDeviceConnection
        else {
            throw RorkDeviceError.secureSessionUnsupported
        }
        return try await InMemoryTLSDeviceConnection.establish(
            over: streamingConnection,
            configuration: configuration
        )
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
    init(
        pairingRecord: PairingRecord,
        profile: LockdownTLSProfile = .standard
    ) throws {
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
            .certificate(hostCertificate)
        ]
        if profile != .hostCertificateOnly,
           let rootCertificateData = pairingRecord.rootCertificate {
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
        configureLockdownProtocolVersions(
            &configuration,
            profile: profile
        )
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

/// Configures the protocol range required by classic Lockdown services.
///
/// Devices before iOS 10 may only negotiate TLS 1.0. Their secure sessions run
/// through a paired usbmux-forwarded channel, and the device certificate is
/// pinned byte-for-byte to the pairing record, so retaining TLS 1.0 is an
/// intentional device-compatibility boundary rather than a public-network trust
/// policy. Remote-pairing TLS remains governed by its separate TLS 1.2 policy.
private func configureLockdownProtocolVersions(
    _ configuration: inout TLSConfiguration,
    profile: LockdownTLSProfile
) {
    configuration.minimumTLSVersion = .tlsv1
    if profile == .tls12 {
        configuration.maximumTLSVersion = .tlsv12
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
    guard
        let prefix = String(
            data: data.prefix(64),
            encoding: .utf8
        )
    else {
        return .der
    }
    return prefix.contains("-----BEGIN ") ? .pem : .der
}
