#if canImport(RorkDeviceLwIP)
import Foundation

/// IPv6/TCP userspace network carried by a Lockdown CoreDevice tunnel.
///
/// This type owns the packet tunnel, runs the packet pumps required by the
/// userspace TCP backend, and exposes device service ports through the standard
/// `DeviceTransport` API. It does not create a system network interface or
/// require elevated privileges.
///
/// The network may be shared across tasks and can open independent device
/// service connections concurrently. Packet forwarding is managed internally.
/// `close()` may be called from any task and is idempotent; closing the network
/// ends its packet pumps and invalidates active and future service connections.
public final class CoreDeviceUserspaceNetwork: DeviceTransport, @unchecked Sendable {
    /// Network parameters negotiated by the owned CoreDevice tunnel.
    public let configuration: CoreDeviceTunnelConfiguration

    /// Maximum duration for each userspace TCP handshake.
    public let connectionTimeout: Duration

    /// Packet tunnel retained for the complete userspace-network lifetime.
    private let tunnel: any CoreDevicePacketTunnel

    /// TCP/IP backend that converts packet traffic into service byte streams.
    private let stack: LwIPNetworkStack

    /// Continuation receiving packets synchronously emitted by lwIP.
    private let outboundContinuation: AsyncStream<Data>.Continuation

    /// Task forwarding lwIP packets to CoreDevice.
    private var outboundTask: Task<Void, Never>?

    /// Task forwarding CoreDevice packets into lwIP.
    private var inboundTask: Task<Void, Never>?

    /// Protects idempotent shutdown across explicit closure and pump failures.
    private let closeLock = NSLock()

    /// Whether the network has already released its tunnel and stack.
    private var isClosed = false

    /// Packet and byte counters maintained by the two packet pumps.
    private let packetCounters = CoreDeviceUserspacePacketCounters()

    /// Completion observed by owners that must follow packet-pump lifetime.
    private let termination = CoreDeviceUserspaceNetworkTermination()

    /// Creates and starts a userspace network over an opened packet tunnel.
    ///
    /// The instance takes ownership of `tunnel`; callers should close the
    /// resulting network rather than closing the tunnel independently.
    ///
    /// - Parameters:
    ///   - tunnel: Negotiated Lockdown CoreDevice packet tunnel.
    ///   - connectionTimeout: Maximum duration for each device TCP handshake.
    /// - Throws: Configuration or network-backend initialization errors.
    public convenience init(
        tunnel: CoreDeviceTunnel,
        connectionTimeout: Duration = .seconds(8)
    ) throws {
        try self.init(
            packetTunnel: tunnel,
            connectionTimeout: connectionTimeout
        )
    }

    /// Creates and starts a userspace network over a remote-pairing tunnel.
    ///
    /// The instance takes ownership of `tunnel`; callers should close the
    /// resulting network rather than closing the tunnel independently.
    ///
    /// - Parameters:
    ///   - tunnel: Negotiated remote-pairing packet tunnel.
    ///   - connectionTimeout: Maximum duration for each device TCP handshake.
    /// - Throws: Configuration or network-backend initialization errors.
    public convenience init(
        tunnel: RemotePairingTunnel,
        connectionTimeout: Duration = .seconds(8)
    ) throws {
        try self.init(
            packetTunnel: tunnel,
            connectionTimeout: connectionTimeout
        )
    }

    /// Creates the shared packet pumps for a supported tunnel implementation.
    private init(
        packetTunnel tunnel: any CoreDevicePacketTunnel,
        connectionTimeout: Duration
    ) throws {
        self.tunnel = tunnel
        configuration = tunnel.configuration
        self.connectionTimeout = connectionTimeout

        let outbound = AsyncStream<Data>.makeStream()
        outboundContinuation = outbound.continuation
        stack = try LwIPNetworkStack(
            localAddress: configuration.hostAddress,
            maximumTransmissionUnit:
                configuration.maximumTransmissionUnit
        ) { packet in
            outbound.continuation.yield(packet)
        }

        outboundTask = Task {
            [weak self, tunnel, stream = outbound.stream, packetCounters] in
            do {
                for await packet in stream {
                    try Task.checkCancellation()
                    try await tunnel.sendPacket(packet)
                    packetCounters.recordSent(byteCount: packet.count)
                }
            } catch {
                self?.close(with: error)
            }
        }
        inboundTask = Task { [weak self, tunnel, stack, packetCounters] in
            do {
                while !Task.isCancelled {
                    let packet = try await tunnel.receivePacket()
                    packetCounters.recordReceived(byteCount: packet.count)
                    try await stack.receivePacket(packet)
                }
            } catch {
                self?.close(with: error)
            }
        }
    }

    deinit {
        close()
    }

    /// Opens one TCP stream to a device service port.
    public func connect(to port: UInt16) async throws -> DeviceConnection {
        guard !closeLock.withLock({ isClosed }) else {
            throw RorkDeviceError.transport(
                "CoreDevice userspace network is closed."
            )
        }
        return try await stack.connect(
            to: configuration.deviceAddress,
            port: port,
            timeout: connectionTimeout
        )
    }

    /// Returns a point-in-time snapshot of network data-plane activity.
    ///
    /// Packet and byte counters cover this network only and survive closure.
    /// Protocol counters come from the shared TCP/IPv6 backend, cover every
    /// active network in the process, and read as zero after closure.
    public func statistics() -> CoreDeviceUserspaceNetworkStatistics {
        let counters = packetCounters.snapshot()
        let protocolStatistics = stack.readProtocolStatistics()
        return CoreDeviceUserspaceNetworkStatistics(
            packetsSent: counters.packetsSent,
            packetsReceived: counters.packetsReceived,
            bytesSent: counters.bytesSent,
            bytesReceived: counters.bytesReceived,
            activeConnections: stack.activeConnectionCount,
            tcpSegmentsSent: protocolStatistics.tcpSegmentsSent,
            tcpSegmentsReceived:
                protocolStatistics.tcpSegmentsReceived,
            tcpSegmentsRetransmitted:
                protocolStatistics.tcpSegmentsRetransmitted,
            tcpDrops: protocolStatistics.tcpDrops,
            tcpErrors: protocolStatistics.tcpErrors,
            ip6PacketsSent: protocolStatistics.ip6PacketsSent,
            ip6PacketsReceived:
                protocolStatistics.ip6PacketsReceived,
            ip6Drops: protocolStatistics.ip6Drops
        )
    }

    /// Stops both packet pumps and closes the owned CoreDevice tunnel.
    ///
    /// Calling this method more than once is safe.
    public func close() {
        close(with: nil)
    }

    /// Waits until explicit closure or a packet-pump failure ends the network.
    ///
    /// Explicit closure completes normally. A failure from either packet pump
    /// is rethrown so long-running gateways can terminate instead of retaining
    /// a listener backed by a dead tunnel.
    func waitUntilClosed() async throws {
        try await termination.wait()
    }

    /// Tears down the complete network after explicit closure or pump failure.
    private func close(with error: Error?) {
        let shouldClose = closeLock.withLock {
            guard !isClosed else {
                return false
            }
            isClosed = true
            return true
        }
        guard shouldClose else {
            return
        }

        outboundContinuation.finish()
        outboundTask?.cancel()
        inboundTask?.cancel()
        outboundTask = nil
        inboundTask = nil
        stack.close(with: error)
        tunnel.close()
        termination.finish(with: error)
    }
}

/// Point-in-time snapshot of userspace-network data-plane activity.
///
/// Packet and byte counters describe traffic pumped between one network's
/// tunnel and its TCP backend. The TCP and IPv6 protocol counters are
/// process-wide because the backend stores statistics globally; they increase
/// monotonically and cover every active network.
public struct CoreDeviceUserspaceNetworkStatistics: Equatable, Sendable {
    /// Complete IPv6 packets forwarded to the device.
    public let packetsSent: UInt64

    /// Complete IPv6 packets received from the device.
    public let packetsReceived: UInt64

    /// Total bytes in packets forwarded to the device.
    public let bytesSent: UInt64

    /// Total bytes in packets received from the device.
    public let bytesReceived: UInt64

    /// TCP connections currently open through this network.
    public let activeConnections: Int

    /// TCP segments transmitted, including retransmissions.
    public let tcpSegmentsSent: UInt32

    /// TCP segments received.
    public let tcpSegmentsReceived: UInt32

    /// TCP segments retransmitted after loss or timeout.
    public let tcpSegmentsRetransmitted: UInt32

    /// TCP segments discarded by protocol processing.
    public let tcpDrops: UInt32

    /// TCP checksum, length, memory, routing, protocol, and option failures.
    public let tcpErrors: UInt32

    /// IPv6 packets transmitted by the backend interface layer.
    public let ip6PacketsSent: UInt32

    /// IPv6 packets received by the backend interface layer.
    public let ip6PacketsReceived: UInt32

    /// IPv6 packets discarded by protocol processing.
    public let ip6Drops: UInt32

    /// Creates a snapshot from independently gathered counters.
    public init(
        packetsSent: UInt64,
        packetsReceived: UInt64,
        bytesSent: UInt64,
        bytesReceived: UInt64,
        activeConnections: Int,
        tcpSegmentsSent: UInt32,
        tcpSegmentsReceived: UInt32,
        tcpSegmentsRetransmitted: UInt32,
        tcpDrops: UInt32,
        tcpErrors: UInt32,
        ip6PacketsSent: UInt32,
        ip6PacketsReceived: UInt32,
        ip6Drops: UInt32
    ) {
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.activeConnections = activeConnections
        self.tcpSegmentsSent = tcpSegmentsSent
        self.tcpSegmentsReceived = tcpSegmentsReceived
        self.tcpSegmentsRetransmitted = tcpSegmentsRetransmitted
        self.tcpDrops = tcpDrops
        self.tcpErrors = tcpErrors
        self.ip6PacketsSent = ip6PacketsSent
        self.ip6PacketsReceived = ip6PacketsReceived
        self.ip6Drops = ip6Drops
    }
}

/// Thread-safe packet and byte counters shared by the two packet pumps.
private final class CoreDeviceUserspacePacketCounters: @unchecked Sendable {
    /// Protects every counter because the pumps run on independent tasks.
    private let lock = NSLock()

    /// Packets forwarded to the device.
    private var packetsSent: UInt64 = 0

    /// Packets received from the device.
    private var packetsReceived: UInt64 = 0

    /// Bytes forwarded to the device.
    private var bytesSent: UInt64 = 0

    /// Bytes received from the device.
    private var bytesReceived: UInt64 = 0

    /// Records one packet forwarded to the device.
    func recordSent(byteCount: Int) {
        lock.withLock {
            packetsSent &+= 1
            bytesSent &+= UInt64(byteCount)
        }
    }

    /// Records one packet received from the device.
    func recordReceived(byteCount: Int) {
        lock.withLock {
            packetsReceived &+= 1
            bytesReceived &+= UInt64(byteCount)
        }
    }

    /// Returns a consistent snapshot of all four counters.
    func snapshot() -> (
        packetsSent: UInt64,
        packetsReceived: UInt64,
        bytesSent: UInt64,
        bytesReceived: UInt64
    ) {
        lock.withLock {
            (packetsSent, packetsReceived, bytesSent, bytesReceived)
        }
    }
}

/// Packet-tunnel operations required by the userspace TCP/IP network.
private protocol CoreDevicePacketTunnel: AnyObject, Sendable {
    /// Network parameters negotiated for the tunnel.
    var configuration: CoreDeviceTunnelConfiguration { get }

    /// Sends one complete IPv6 packet to the device.
    func sendPacket(_ packet: Data) async throws

    /// Receives one complete IPv6 packet from the device.
    func receivePacket() async throws -> Data

    /// Closes the tunnel and any pending packet operations.
    func close()
}

/// Allows Lockdown-created tunnels to back the userspace network.
extension CoreDeviceTunnel: CoreDevicePacketTunnel {}

/// Allows remote-pairing tunnels to back the userspace network.
extension RemotePairingTunnel: CoreDevicePacketTunnel {}

/// One-shot completion shared by userspace-network owners.
///
/// Packet pumps can fail on independent tasks while a gateway is suspended in
/// another task. This object stores the first terminal result and resumes every
/// waiter outside its lock.
private final class CoreDeviceUserspaceNetworkTermination: @unchecked Sendable {
    /// Protects the terminal result and registered waiters.
    private let lock = NSLock()

    /// First explicit-close or failure result delivered by the network.
    private var result: Result<Void, Error>?

    /// Owners suspended until the network reaches a terminal state.
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Suspends until the network closes, then returns or rethrows its failure.
    func wait() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let terminalResult: Result<Void, Error>? = lock.withLock {
                if let result = self.result {
                    return result
                }
                waiters.append(continuation)
                return nil
            }
            if let terminalResult {
                continuation.resume(with: terminalResult)
            }
        }
    }

    /// Publishes the first terminal result to current and future waiters.
    func finish(with error: Error?) {
        let result: Result<Void, Error> =
            error.map { .failure($0) }
            ?? .success(())
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard self.result == nil else {
                return []
            }
            self.result = result
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
#endif
