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

    /// Backoff for re-driving full enrollment after a pre-completion failure.
    ///
    /// On iOS 26.x the untrusted pairing stream can be reset before the device
    /// stores the identity — sometimes before the on-device Trust prompt is even
    /// actionable. Re-driving the full setup (rather than only re-verifying an
    /// identity the device never accepted, which can never succeed) gives the
    /// prompt repeated, stable opportunities to be approved while a transient
    /// reset clears. The first attempt is immediate; the bounded window lets a
    /// device that keeps refusing fail in finite time instead of looping forever.
    private static let enrollmentBackoff = Backoff.exponential(
        initial: .milliseconds(500),
        factor: 2,
        maximum: .seconds(5),
        maxAttempts: 10
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
    /// backoff schedules bound how long enrollment is re-driven and how long the
    /// stored identity is re-verified.
    static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        discoveryPort: UInt16,
        progress: @escaping (Progress) -> Void = { _ in },
        enrollmentBackoff: Backoff = Self.enrollmentBackoff,
        verificationBackoff: Backoff = Self.verificationBackoff,
        sleep: (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        openConnection: (UInt16) async throws -> DeviceConnection
    ) async throws {
        try await establishWithRecovery(
            progress: progress,
            enrollmentBackoff: enrollmentBackoff,
            verificationBackoff: verificationBackoff,
            sleep: sleep,
            initialAttempt: { willBeginEnrollment, didEnrollIdentity in
                try await withPairingClient(
                    for: identity,
                    discoveryPort: discoveryPort,
                    progress: progress,
                    openConnection: openConnection
                ) { client in
                    try await client.establishTrustIfNeeded(
                        willEstablishTrust:
                            willBeginEnrollment,
                        didEnrollIdentity: didEnrollIdentity
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

    /// Establishes trust, re-driving setup until the device stores the identity.
    ///
    /// Each attempt verifies the identity or, when the device does not recognise
    /// it, performs manual pair setup. The recovery depends on how far an attempt
    /// got before failing:
    ///
    /// - **Before enrollment begins** (the initial verify fails at the transport
    ///   level): the failure is propagated. The caller decides whether to retry,
    ///   matching the previous contract.
    /// - **After enrollment begins but before the identity is stored**: the
    ///   untrusted stream was reset before the device accepted the identity (the
    ///   iOS 26.x failure), so verifying it could never succeed. The full setup
    ///   is re-driven on a fresh connection, with backoff, giving the on-device
    ///   Trust prompt another stable opportunity to be approved.
    /// - **After the identity is stored** (`didEnrollIdentity` fired): the device
    ///   may reset the stream as the final step of a successful pairing, so the
    ///   identity is confirmed by re-verifying it — never by submitting setup
    ///   again, which would request a second approval.
    static func establishWithRecovery(
        progress: @escaping (Progress) -> Void,
        enrollmentBackoff: Backoff,
        verificationBackoff: Backoff,
        sleep: (Duration) async throws -> Void,
        initialAttempt: (
            _ willBeginEnrollment: () -> Void,
            _ didEnrollIdentity: () -> Void
        ) async throws -> Void,
        verificationAttempt: () async throws -> Void
    ) async throws {
        var didBeginEnrollment = false
        var didEnrollIdentity = false

        do {
            try await retry(
                enrollmentBackoff,
                sleep: sleep,
                isRetryable: { error in
                    // Re-drive the full setup only when enrollment began but the
                    // device has not stored the identity yet (the iOS 26.x reset
                    // before consent). A failure before enrollment begins — or
                    // after the identity is stored — stops the re-drive loop.
                    didBeginEnrollment
                        && !didEnrollIdentity
                        && isRetryableEnrollmentRecoveryError(error)
                }
            ) {
                didBeginEnrollment = false
                didEnrollIdentity = false
                try await initialAttempt(
                    {
                        didBeginEnrollment = true
                        progress(.enrollingIdentity)
                    },
                    {
                        didEnrollIdentity = true
                    }
                )
            }
            progress(.established)
            return
        } catch {
            // The enrollment loop stopped. Only fall back to verification when the
            // device has stored the identity *and* the failure is a recoverable
            // disconnect — the device may reset the stream as the final step of a
            // successful pairing, which is confirmed by verifying on fresh
            // connections (never by re-submitting setup, which would request a
            // second approval). Anything else — a reset before enrollment began,
            // or a non-retryable error such as a protocol violation, a hard
            // rejection, or cancellation — belongs to the caller.
            guard
                didEnrollIdentity,
                isRetryableEnrollmentRecoveryError(error)
            else {
                throw error
            }
        }

        try await retry(
            verificationBackoff,
            sleep: sleep,
            isRetryable: { isRetryableEnrollmentRecoveryError($0) }
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
