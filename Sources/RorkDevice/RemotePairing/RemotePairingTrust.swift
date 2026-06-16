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
        progress: (Progress) -> Void = { _ in }
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
    /// testable without exposing transport internals in the public API.
    static func establishIfNeeded(
        for identity: RemotePairingIdentity,
        discoveryPort: UInt16,
        progress: (Progress) -> Void = { _ in },
        openConnection: (UInt16) async throws -> DeviceConnection
    ) async throws {
        progress(.openingServiceDiscovery)
        let discoveryConnection = try await openConnection(
            discoveryPort
        )
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
        try await RemotePairingProtocolClient(
            channel: channel,
            identity: identity
        ).establishTrustIfNeeded {
            progress(.enrollingIdentity)
        }
        progress(.established)
    }
}
