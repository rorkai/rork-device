#if canImport(BigInt)
import Foundation

/// Establishes the device-side trust required by a remote-pairing identity.
///
/// Remote pairing is separate from Lockdown trust. A valid Lockdown pairing
/// record therefore does not imply that the device recognizes the identity used
/// by `RemotePairingTunnel`. This API first performs pair verification and only
/// enters Apple's manual trust flow when the device reports authentication
/// failure or an unknown peer. Rate limits and capacity failures remain typed
/// errors for the caller to handle.
public enum RemotePairingTrust {
    /// Observable phases of remote-pairing trust establishment.
    ///
    /// The values identify network and user-interaction boundaries without
    /// exposing protocol messages or credential material. Applications can use
    /// them for progress UI and diagnostics while the async operation remains
    /// the single source of success or failure.
    public enum Progress: Equatable, Sendable {
        /// Opening and decoding the Remote Service Discovery advertisement.
        case openingServiceDiscovery

        /// Connecting to the untrusted remote-pairing service advertised by RSD.
        case openingPairingService

        /// Checking whether the device already recognizes the host identity.
        case verifyingIdentity

        /// Registering an unknown identity, which may require device approval.
        case enrollingIdentity

        /// The device accepts the identity for future remote-pairing sessions.
        case established
    }

    /// RSD service that accepts identities before remote trust exists.
    private static let untrustedTunnelServiceName =
        "com.apple.internal.dt.coredevice.untrusted.tunnelservice"

    /// Backoff for fresh verification attempts after the device stores the
    /// identity.
    ///
    /// The first attempt is immediate. Later attempts cover the short interval
    /// in which the device has accepted the identity but has not yet published
    /// it to a newly opened remote-pairing service.
    private static let verificationBackoff = Backoff.exponential(
        initial: .milliseconds(500),
        factor: 2,
        maximum: .seconds(8),
        maxAttempts: 6
    )

    /// Establishes device trust for an identity when it is not already known.
    ///
    /// An unrecognized identity cannot use the device's trusted pairing
    /// service. This method keeps Remote Service Discovery alive, resolves the
    /// untrusted pairing service, and performs pair verification or manual
    /// setup over RemoteXPC. The supplied transport may be the package's
    /// embedded userspace network or an independently managed gateway.
    ///
    /// Once enrollment starts, retryable disconnects and unknown-peer responses
    /// are resolved by verifying the same identity on fresh service connections.
    /// The operation never submits the enrollment request a second time.
    ///
    /// - Parameters:
    ///   - identity: Host identity that future remote-pairing tunnels will use.
    ///   - transport: Route capable of opening ports on the selected device.
    ///   - discoveryPort: Live Remote Service Discovery port reported for that
    ///     route.
    ///   - progress: Synchronous observer called when the operation crosses a
    ///     meaningful network or approval boundary.
    /// - Throws: Transport, cryptographic, typed pairing rejection, or malformed
    ///   protocol errors.
    public static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        using transport: any DeviceTransport,
        discoveryPort: UInt16,
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        guard discoveryPort > 0 else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing requires a nonzero discovery port."
            )
        }
        try await establishIfNeeded(
            for: identity,
            discoveryPort: discoveryPort,
            progress: progress
        ) { port in
            try await transport.connect(to: port)
        }
    }

    /// Shared implementation used by production routes and transport tests.
    static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        openConnection: () async throws -> DeviceConnection
    ) async throws {
        let connection = try await openConnection()
        defer {
            connection.close()
        }
        try await RemotePairingProtocolClient(
            connection: connection,
            identity: identity
        ).establishTrustIfNeeded()
    }

    /// Resolves the untrusted service and performs pairing over RemoteXPC.
    ///
    /// The injected connection factory keeps discovery and service lifetimes
    /// testable without exposing transport internals in the public API. The
    /// verification backoff bounds how long a stored identity is re-verified
    /// after the enrollment stream resets.
    static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        discoveryPort: UInt16,
        progress: @escaping (Progress) -> Void = { _ in },
        verificationBackoff: Backoff = Self.verificationBackoff,
        sleep: (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        openConnection: (UInt16) async throws -> DeviceConnection
    ) async throws {
        try await establishWithRecovery(
            progress: progress,
            verificationBackoff: verificationBackoff,
            sleep: sleep,
            initialAttempt: { willBeginEnrollment in
                try await withPairingClient(
                    for: identity,
                    discoveryPort: discoveryPort,
                    progress: progress,
                    openConnection: openConnection
                ) { client in
                    try await client.establishTrustIfNeeded(
                        willEstablishTrust: willBeginEnrollment
                    )
                }
            },
            verificationAttempt: {
                try await withPairingClient(
                    for: identity,
                    discoveryPort: discoveryPort,
                    progress: progress,
                    openConnection: openConnection
                ) { client in
                    try await client.verifyTrust()
                }
            }
        )
    }

    /// Establishes trust, confirming a stored identity by re-verifying after a reset.
    ///
    /// The attempt verifies the identity or, when the device does not recognize
    /// it, performs manual pair setup. Recovery depends on how far it reached:
    ///
    /// - **Before enrollment begins** (the initial verify fails at the transport
    ///   level): the failure is propagated for the caller to retry.
    /// - **After enrollment begins**: the device may reset the untrusted stream
    ///   as the final step of storing the identity, so the identity is confirmed
    ///   by re-verifying it on fresh connections — never by repeating setup,
    ///   which would request a second approval. Verification is retried while the
    ///   device publishes the stored identity; a device that never stores it
    ///   fails once the bounded window elapses.
    static func establishWithRecovery(
        progress: @escaping (Progress) -> Void,
        verificationBackoff: Backoff,
        sleep: (Duration) async throws -> Void,
        initialAttempt: (_ willBeginEnrollment: () -> Void) async throws -> Void,
        verificationAttempt: () async throws -> Void
    ) async throws {
        var didBeginEnrollment = false
        do {
            try await initialAttempt {
                didBeginEnrollment = true
                progress(.enrollingIdentity)
            }
            progress(.established)
            return
        } catch {
            // A failure before enrollment begins, or any non-retryable failure,
            // belongs to the caller. Otherwise the device may have stored the
            // identity as it reset the stream, so confirm by verifying it.
            guard didBeginEnrollment, isRetryableEnrollmentRecoveryError(error)
            else {
                throw error
            }
        }

        try await retry(
            verificationBackoff,
            sleep: sleep,
            isRetryable: isRetryableEnrollmentRecoveryError
        ) {
            try await verificationAttempt()
        }
        progress(.established)
    }

    /// Opens one complete RSD and untrusted pairing-service session.
    ///
    /// Every invocation owns fresh discovery and RemoteXPC connections. This
    /// matters after enrollment because the device may terminate both service
    /// streams while retaining the newly approved identity.
    private static func withPairingClient<Success>(
        for identity: RemotePairingIdentity,
        discoveryPort: UInt16,
        progress: (Progress) -> Void,
        openConnection: (UInt16) async throws -> DeviceConnection,
        operation: (RemotePairingProtocolClient) async throws -> Success
    ) async throws -> Success {
        progress(.openingServiceDiscovery)
        let discoveryConnection = try await openConnection(discoveryPort)
        let discovery = try await RemoteServiceDiscoverySession.open(
            over: discoveryConnection
        )
        defer {
            discovery.close()
        }

        guard
            let servicePort = discovery.directory.port(
                for: untrustedTunnelServiceName
            )
        else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery did not advertise \(untrustedTunnelServiceName)."
            )
        }

        progress(.openingPairingService)
        let serviceConnection = try await openConnection(servicePort)
        let channel = try await RemotePairingRemoteXPCChannel.open(
            over: serviceConnection
        )
        defer {
            channel.close()
        }
        progress(.verifyingIdentity)
        return try await operation(
            RemotePairingProtocolClient(
                channel: channel,
                identity: identity
            )
        )
    }

    /// Identifies failures that can occur while approved trust is propagating.
    private static func isRetryableEnrollmentRecoveryError(
        _ error: Error
    ) -> Bool {
        guard let deviceError = error as? RorkDeviceError else {
            return false
        }
        switch deviceError {
        case .transport, .remoteXPCStreamReset:
            return true
        case .remotePairing(let rejection):
            return rejection.allowsPairSetup
        default:
            return false
        }
    }
}
#endif
