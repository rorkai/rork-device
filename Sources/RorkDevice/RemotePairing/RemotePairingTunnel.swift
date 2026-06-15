import Foundation
#if canImport(Network)
import Network
#endif

/// Authenticated IPv6 packet tunnel to an iOS remote-pairing endpoint.
///
/// Connection setup performs pair verification with `RemotePairingIdentity`,
/// asks the device to create a TCP tunnel listener, protects that listener with
/// TLS 1.2 PSK, and completes the packet-tunnel handshake. The resulting stream
/// carries complete IPv6 packets rather than a general-purpose byte protocol.
///
/// Keep the instance alive while using RSD-backed `DeviceSession` connections.
/// Closing the tunnel invalidates every service socket routed through it.
public final class RemotePairingTunnel {
    /// Whether this build contains the TLS-PSK backend required by remote pairing.
    ///
    /// The generic connection API remains available when the package is built
    /// without Apple's networking frameworks. When this value is `false`,
    /// `connect(to:port:using:requestedMaximumTransmissionUnit:timeout:)` fails
    /// with `RorkDeviceError.secureSessionUnsupported` before opening a network
    /// connection.
    public static var isSupported: Bool {
        #if canImport(Network) && canImport(Security)
        true
        #else
        false
        #endif
    }

    /// Network parameters negotiated for this tunnel instance.
    ///
    /// These values remain meaningful only while the tunnel is open. Use them
    /// to configure the host packet interface and to reach the device's Remote
    /// Service Discovery endpoint through that interface.
    public let configuration: RemotePairingTunnelConfiguration

    /// IANA name and wire value of the TLS cipher suite protecting packet traffic.
    ///
    /// The value is diagnostic metadata captured after the PSK handshake. It is
    /// `nil` when the active transport cannot report TLS state. Callers should
    /// not use it to make routing or compatibility decisions.
    public let tlsCipherSuite: String?

    /// Pair-verification stream retained until the tunnel closes.
    private let controlConnection: DeviceConnection

    /// TLS-protected stream that carries complete IPv6 packets.
    private let tunnelConnection: DeviceConnection

    /// Actor that serializes writes so concurrent packets cannot interleave.
    private let writer: RemotePairingPacketWriter

    /// Creates an owned tunnel from established control and packet streams.
    init(
        configuration: RemotePairingTunnelConfiguration,
        tlsCipherSuite: String? = nil,
        controlConnection: DeviceConnection,
        tunnelConnection: DeviceConnection
    ) {
        self.configuration = configuration
        self.tlsCipherSuite = tlsCipherSuite
        self.controlConnection = controlConnection
        self.tunnelConnection = tunnelConnection
        writer = RemotePairingPacketWriter(connection: tunnelConnection)
    }

    /// Authenticates a host identity and negotiates an IPv6 packet tunnel.
    ///
    /// The initial control connection is plain TCP. Successful pair verification
    /// derives the pre-shared key used for a second TLS 1.2 connection, which is
    /// then upgraded to the packet tunnel represented by the returned instance.
    ///
    /// - Parameters:
    ///   - host: Address of the device's remote-pairing control endpoint.
    ///   - port: Remote-pairing control port. Defaults to `49152`.
    ///   - identity: Host identity previously accepted by the target device.
    ///   - requestedMaximumTransmissionUnit: Maximum packet size requested
    ///     during tunnel negotiation.
    ///   - timeout: Maximum duration for each outbound TCP connection.
    /// - Returns: Connected tunnel with negotiated network parameters.
    /// - Throws: Pairing, cryptographic, transport, or protocol errors. Partially
    ///   opened connections are closed before the error is returned.
    public static func connect(
        to host: String,
        port: UInt16 = 49_152,
        using identity: RemotePairingIdentity,
        requestedMaximumTransmissionUnit: UInt16 = 16_000,
        timeout: Duration = .seconds(8)
    ) async throws -> RemotePairingTunnel {
        #if canImport(Network) && canImport(Security)
        let controlConnection = try await TCPDeviceConnection.connect(
            to: host,
            port: port,
            timeout: timeout
        )

        return try await establish(
            controlConnection: controlConnection,
            identity: identity,
            requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit
        ) { listener in
            let connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: listener.port,
                preSharedKey: listener.preSharedKey,
                timeout: timeout
            )
            return RemotePairingTunnelStream(
                connection: connection,
                tlsCipherSuite: connection.tlsCipherSuite
            )
        }
        #else
        throw RorkDeviceError.secureSessionUnsupported
        #endif
    }

    #if canImport(Network) && canImport(Security)
    /// Authenticates through a specific network interface and negotiates an IPv6 packet tunnel.
    ///
    /// Use this overload from a packet-tunnel provider when the remote-pairing
    /// endpoint is reachable only through the provider's own virtual interface.
    /// NetworkExtension normally excludes provider-originated connections from
    /// the tunnel. This method binds the SwiftNIO pair-verification socket to
    /// the interface index and requires the same interface on the TLS-PSK socket
    /// created for the device's dynamically assigned listener.
    ///
    /// - Parameters:
    ///   - host: Address of the device's remote-pairing control endpoint.
    ///   - port: Remote-pairing control port. Defaults to `49152`.
    ///   - identity: Host identity previously accepted by the target device.
    ///   - interface: Network interface that must carry both outbound
    ///     connections. Pass `NEPacketTunnelProvider.virtualInterface` when
    ///     connecting through the provider's packet flow.
    ///   - requestedMaximumTransmissionUnit: Maximum packet size requested
    ///     during tunnel negotiation.
    ///   - timeout: Maximum duration for each outbound TCP connection.
    /// - Returns: Connected tunnel with negotiated network parameters.
    /// - Throws: Pairing, cryptographic, transport, or protocol errors. Partially
    ///   opened connections are closed before the error is returned.
    public static func connect(
        to host: String,
        port: UInt16 = 49_152,
        using identity: RemotePairingIdentity,
        through interface: NWInterface,
        requestedMaximumTransmissionUnit: UInt16 = 16_000,
        timeout: Duration = .seconds(8)
    ) async throws -> RemotePairingTunnel {
        guard interface.index > 0,
              let interfaceIndex = UInt32(exactly: interface.index) else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing requires a valid network interface index."
            )
        }

        let controlConnection = try await TCPDeviceConnection.connect(
            to: host,
            port: port,
            boundToIPv4Interface: interfaceIndex,
            timeout: timeout
        )

        return try await establish(
            controlConnection: controlConnection,
            identity: identity,
            requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit
        ) { listener in
            let connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: listener.port,
                preSharedKey: listener.preSharedKey,
                through: interface,
                timeout: timeout
            )
            return RemotePairingTunnelStream(
                connection: connection,
                tlsCipherSuite: connection.tlsCipherSuite
            )
        }
    }
    #endif

    /// Completes pair verification, opens the protected stream, and negotiates the link.
    private static func establish(
        controlConnection: DeviceConnection,
        identity: RemotePairingIdentity,
        requestedMaximumTransmissionUnit: UInt16,
        openTunnelConnection: (RemotePairingTunnelListener) async throws -> RemotePairingTunnelStream
    ) async throws -> RemotePairingTunnel {
        var tunnelConnection: DeviceConnection?
        do {
            let listener = try await RemotePairingProtocolClient(
                connection: controlConnection,
                identity: identity
            ).createTunnelListener()
            let stream = try await openTunnelConnection(listener)
            tunnelConnection = stream.connection
            let configuration = try await CDTunnelProtocol.negotiateConfiguration(
                over: stream.connection,
                requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit
            )
            return RemotePairingTunnel(
                configuration: configuration,
                tlsCipherSuite: stream.tlsCipherSuite,
                controlConnection: controlConnection,
                tunnelConnection: stream.connection
            )
        } catch {
            tunnelConnection?.close()
            controlConnection.close()
            throw error
        }
    }

    /// Sends one complete IPv6 packet through the tunnel.
    ///
    /// Concurrent calls are serialized so packet boundaries remain intact on
    /// the underlying TLS stream.
    ///
    /// - Parameter packet: Complete IPv6 packet, including its 40-byte header.
    /// - Throws: `RorkDeviceError.invalidInput` for non-IPv6 data, or a transport
    ///   error when the tunnel is closed or the write fails.
    public func sendPacket(_ packet: Data) async throws {
        guard packet.first.map({ $0 >> 4 }) == 6 else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing tunnel only accepts IPv6 packets."
            )
        }
        try await writer.send(packet)
    }

    /// Receives one complete IPv6 packet from the tunnel.
    ///
    /// The method reads the fixed IPv6 header first, then the exact payload
    /// length declared by that header.
    ///
    /// - Returns: Complete IPv6 packet including its header.
    /// - Throws: A protocol error for malformed framing or a transport error when
    ///   the tunnel closes before the packet is complete.
    public func receivePacket() async throws -> Data {
        try await CDTunnelProtocol.receivePacket(from: tunnelConnection)
    }

    /// Closes both the remote-pairing control stream and packet stream.
    ///
    /// Calling this method more than once is safe. Any active or future packet
    /// operation fails through its underlying connection.
    public func close() {
        tunnelConnection.close()
        controlConnection.close()
    }
}

/// Packet stream and security metadata produced by remote-pairing TLS setup.
private struct RemotePairingTunnelStream {
    /// TLS-protected connection that carries complete IPv6 packets.
    let connection: DeviceConnection

    /// Cipher description captured after the connection became ready.
    let tlsCipherSuite: String?
}

/// Serializes writes to the packet stream while preserving async cancellation.
private actor RemotePairingPacketWriter {
    /// Packet stream shared by all callers of `send(_:)`.
    private let connection: DeviceConnection

    /// Creates a writer that does not take ownership beyond the tunnel lifetime.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Writes one already validated IPv6 packet without changing its framing.
    func send(_ packet: Data) async throws {
        try await connection.send(packet)
    }
}
