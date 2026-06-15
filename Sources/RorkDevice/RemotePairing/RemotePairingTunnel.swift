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
    /// Whether the default transport can establish a remote-pairing tunnel.
    ///
    /// The connection API remains available in builds without a compatible
    /// transport implementation. When this value is `false`,
    /// `connect(to:port:using:requestedMaximumTransmissionUnit:timeout:)` fails
    /// with `RorkDeviceError.secureSessionUnsupported` before opening a network
    /// connection.
    public static var isSupported: Bool {
        RemotePairingTransportProvider.isSupported
    }

    /// Network parameters negotiated for this tunnel instance.
    ///
    /// These values remain meaningful only while the tunnel is open. Use them
    /// to configure the host packet interface and to reach the device's Remote
    /// Service Discovery endpoint through that interface.
    public let configuration: RemotePairingTunnelConfiguration

    /// TLS cipher suite protecting packet traffic.
    ///
    /// The value is diagnostic metadata captured after the PSK handshake. It is
    /// `nil` when the active transport cannot report TLS state. Callers should
    /// not use the value to make routing or compatibility decisions.
    public let tlsCipherSuite: RemotePairingTLSCipherSuite?

    /// Pair-verification stream retained until the tunnel closes.
    private let controlConnection: DeviceConnection

    /// Full-duplex stream that carries complete IPv6 packets.
    private let packetConnection: RemotePairingPacketConnection

    /// Writer that prevents concurrent packet sends from overlapping.
    private let writer: RemotePairingPacketWriter

    /// Creates an owned tunnel from established control and packet streams.
    init(
        configuration: RemotePairingTunnelConfiguration,
        tlsCipherSuite: RemotePairingTLSCipherSuite? = nil,
        controlConnection: DeviceConnection,
        tunnelConnection: DeviceConnection
    ) {
        let packetConnection = RemotePairingPacketConnection(
            connection: tunnelConnection
        )
        self.configuration = configuration
        self.tlsCipherSuite = tlsCipherSuite
        self.controlConnection = controlConnection
        self.packetConnection = packetConnection
        writer = RemotePairingPacketWriter(connection: packetConnection)
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
        let transport = try RemotePairingTransportProvider.makeDefault()
        return try await connect(
            to: host,
            port: port,
            using: identity,
            requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit,
            timeout: timeout,
            transport: transport
        )
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
        let transport = try RemotePairingTransportProvider.makeDefault()
        return try await connect(
            to: host,
            port: port,
            using: identity,
            requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit,
            timeout: timeout,
            transport: transport,
            over: .networkInterface(interface)
        )
    }
    #endif

    /// Connects using a specific transport and routing policy.
    ///
    /// Platform selection remains internal so adding a portable transport does not
    /// expand or alter the public tunnel API.
    static func connect(
        to host: String,
        port: UInt16 = 49_152,
        using identity: RemotePairingIdentity,
        requestedMaximumTransmissionUnit: UInt16 = 16_000,
        timeout: Duration = .seconds(8),
        transport: any RemotePairingTransport,
        over route: RemotePairingTransportRoute = .systemDefault
    ) async throws -> RemotePairingTunnel {
        let controlConnection = try await transport.openControlConnection(
            to: host,
            port: port,
            over: route,
            timeout: timeout
        )

        return try await establish(
            controlConnection: controlConnection,
            identity: identity,
            requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit
        ) { listener in
            try await transport.openTLSConnection(
                to: host,
                port: listener.port,
                using: listener.preSharedKey,
                over: route,
                timeout: timeout
            )
        }
    }

    /// Completes pair verification, opens the protected stream, and negotiates the link.
    private static func establish(
        controlConnection: DeviceConnection,
        identity: RemotePairingIdentity,
        requestedMaximumTransmissionUnit: UInt16,
        openTLSConnection: (RemotePairingTunnelListener) async throws -> RemotePairingTLSConnection
    ) async throws -> RemotePairingTunnel {
        var tunnelConnection: DeviceConnection?
        do {
            let listener = try await RemotePairingProtocolClient(
                connection: controlConnection,
                identity: identity
            ).createTunnelListener()
            let stream = try await openTLSConnection(listener)
            tunnelConnection = stream.connection
            let configuration = try await CDTunnelProtocol.negotiateConfiguration(
                over: stream.connection,
                requestedMaximumTransmissionUnit: requestedMaximumTransmissionUnit
            )
            return RemotePairingTunnel(
                configuration: configuration,
                tlsCipherSuite: stream.cipherSuite,
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
        try await packetConnection.receivePacket()
    }

    /// Closes both the remote-pairing control stream and packet stream.
    ///
    /// Calling this method more than once is safe. Any active or future packet
    /// operation fails through its underlying connection.
    public func close() {
        packetConnection.close()
        controlConnection.close()
    }
}

/// Shares the packet stream across the tunnel's read and write tasks.
///
/// Remote-pairing transports provide a full-duplex connection that permits one
/// reader and ordered writes concurrently. The unchecked conformance is scoped
/// to this private wrapper so the general `DeviceConnection` protocol does not
/// claim concurrency guarantees that every service transport may not provide.
private final class RemotePairingPacketConnection: @unchecked Sendable {
    /// Full-duplex connection supplied by the selected remote-pairing transport.
    private let connection: DeviceConnection

    /// Creates a concurrency-scoped wrapper around the protected packet stream.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Sends one complete IPv6 packet.
    func send(_ packet: Data) async throws {
        try await connection.send(packet)
    }

    /// Receives one complete IPv6 packet.
    func receivePacket() async throws -> Data {
        try await CDTunnelProtocol.receivePacket(from: connection)
    }

    /// Closes the protected packet stream.
    func close() {
        connection.close()
    }
}

/// Serializes packet writes across actor reentrancy.
///
/// Actor isolation alone is insufficient because `send(_:)` suspends while the
/// transport writes and another actor task may run during that suspension. The
/// explicit write slot keeps later callers queued until the active write has
/// completed or failed.
private actor RemotePairingPacketWriter {
    /// Packet stream shared by all callers of `send(_:)`.
    private let connection: RemotePairingPacketConnection

    /// Whether one caller currently owns the write slot.
    private var isWriteInProgress = false

    /// Callers waiting to acquire the write slot, in arrival order.
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a writer that does not take ownership beyond the tunnel lifetime.
    init(connection: RemotePairingPacketConnection) {
        self.connection = connection
    }

    /// Writes one validated IPv6 packet after earlier writes finish.
    ///
    /// Cancellation is checked both before queueing and after the write slot is
    /// acquired. A task cancelled while waiting leaves the queue when its turn
    /// arrives, then releases the slot without invoking the transport.
    func send(_ packet: Data) async throws {
        try Task.checkCancellation()
        await acquireWriteSlot()
        defer {
            releaseWriteSlot()
        }
        try Task.checkCancellation()
        try await connection.send(packet)
    }

    /// Suspends until this caller exclusively owns the transport write slot.
    private func acquireWriteSlot() async {
        guard isWriteInProgress else {
            isWriteInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    /// Transfers the write slot to the next waiter or marks it as available.
    private func releaseWriteSlot() {
        guard !writeWaiters.isEmpty else {
            isWriteInProgress = false
            return
        }

        writeWaiters.removeFirst().resume()
    }
}
