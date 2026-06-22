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

    /// Delays before fresh verification attempts after identity enrollment.
    ///
    /// The first attempt is immediate. Later attempts cover the short interval
    /// in which the device has accepted the identity but has not yet published
    /// it to a newly opened remote-pairing service.
    private static let enrollmentRecoveryDelays: [Duration] = [
        .zero,
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
    ]

    /// Establishes device trust for an identity when it is not already known.
    ///
    /// An unrecognized identity cannot use the device's trusted pairing
    /// service. This method keeps Remote Service Discovery alive, resolves the
    /// untrusted pairing service, and performs pair verification or manual
    /// setup over RemoteXPC. The supplied transport may be the package's
    /// embedded userspace network or an independently managed gateway.
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
    /// testable without exposing transport internals in the public API. Retry
    /// delays include the wait before each fresh verification, so a leading
    /// `.zero` performs the first recovery attempt immediately.
    static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        discoveryPort: UInt16,
        progress: @escaping (Progress) -> Void = { _ in },
        verificationRetryDelays: [Duration] =
            Self.enrollmentRecoveryDelays,
        sleep: (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        openConnection: (UInt16) async throws -> DeviceConnection
    ) async throws {
        try await establishWithRecovery(
            progress: progress,
            verificationRetryDelays: verificationRetryDelays,
            sleep: sleep,
            initialAttempt: {
                willBeginEnrollment,
                didEnrollIdentity in
                try await withPairingClient(
                    for: identity,
                    discoveryPort: discoveryPort,
                    progress: progress,
                    openConnection: openConnection,
                    operation: { client in
                        try await client.establishTrustIfNeeded(
                            willEstablishTrust:
                                willBeginEnrollment,
                            didEnrollIdentity:
                                didEnrollIdentity
                        )
                    }
                )
            },
            verificationAttempt: {
                try await withPairingClient(
                    for: identity,
                    discoveryPort: discoveryPort,
                    progress: progress,
                    openConnection: openConnection,
                    operation: { client in
                        try await client.verifyTrust()
                    }
                )
            }
        )
    }

    /// Applies post-enrollment recovery around one protocol attempt.
    ///
    /// Starting setup is not enough to infer that the device stored the
    /// identity. Recovery becomes valid only after the protocol client reports
    /// that M6 was accepted, and it never starts setup a second time.
    static func establishWithRecovery(
        progress: @escaping (Progress) -> Void,
        verificationRetryDelays: [Duration],
        sleep: (Duration) async throws -> Void,
        initialAttempt: (
            _ willBeginEnrollment: () -> Void,
            _ didEnrollIdentity: () -> Void
        ) async throws -> Void,
        verificationAttempt: () async throws -> Void
    ) async throws {
        var didEnrollIdentity = false
        var postEnrollmentError: Error?

        do {
            try await initialAttempt(
                {
                    progress(.enrollingIdentity)
                },
                {
                    didEnrollIdentity = true
                }
            )
        } catch {
            guard didEnrollIdentity,
                  isRetryableEnrollmentRecoveryError(error) else {
                throw error
            }
            postEnrollmentError = error
        }

        if didEnrollIdentity {
            try await verifyTrustAfterEnrollment(
                retryDelays: verificationRetryDelays,
                sleep: sleep,
                verificationAttempt: verificationAttempt,
                postEnrollmentError: postEnrollmentError
            )
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

        guard let servicePort = discovery.directory.port(
            for: untrustedTunnelServiceName
        ) else {
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

    /// Confirms enrollment on fresh service connections without repeating setup.
    ///
    /// Authentication and unknown-peer responses remain retryable briefly
    /// because they can reflect propagation delay after approval. Transport and
    /// subsequent stream resets are retried for the same reason. Device rate
    /// limits, capacity failures, malformed responses, and cryptographic errors
    /// leave immediately.
    private static func verifyTrustAfterEnrollment(
        retryDelays: [Duration],
        sleep: (Duration) async throws -> Void,
        verificationAttempt: () async throws -> Void,
        postEnrollmentError: Error?
    ) async throws {
        guard !retryDelays.isEmpty else {
            if let postEnrollmentError {
                throw postEnrollmentError
            }
            throw RorkDeviceError.invalidInput(
                "Post-enrollment verification requires at least one attempt."
            )
        }

        for (index, delay) in retryDelays.enumerated() {
            if delay != .zero {
                try await sleep(delay)
            }
            do {
                try await verificationAttempt()
                return
            } catch {
                let hasNextAttempt = index + 1 < retryDelays.count
                guard hasNextAttempt,
                      isRetryableEnrollmentRecoveryError(error) else {
                    throw error
                }
            }
        }
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
        case let .remotePairing(rejection):
            return rejection.allowsPairSetup
        default:
            return false
        }
    }
}
