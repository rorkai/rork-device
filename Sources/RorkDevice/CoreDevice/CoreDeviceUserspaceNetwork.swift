import Foundation

/// IPv6/TCP userspace network carried by a Lockdown CoreDevice tunnel.
///
/// This type owns the packet tunnel, runs the packet pumps required by the
/// userspace TCP backend, and exposes device service ports through the standard
/// `DeviceTransport` API. It does not create a system network interface or
/// require elevated privileges.
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

        outboundTask = Task { [weak self, tunnel] in
            do {
                for await packet in outbound.stream {
                    try Task.checkCancellation()
                    try await tunnel.sendPacket(packet)
                }
            } catch {
                self?.close(with: error)
            }
        }
        inboundTask = Task { [weak self, tunnel, stack] in
            do {
                while !Task.isCancelled {
                    let packet = try await tunnel.receivePacket()
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

/// Packet-tunnel operations required by the userspace TCP/IP network.
private protocol CoreDevicePacketTunnel: AnyObject {
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
        let result: Result<Void, Error> = error.map { .failure($0) }
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
