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
    private let tunnel: CoreDeviceTunnel

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

    /// Creates and starts a userspace network over an opened packet tunnel.
    ///
    /// The instance takes ownership of `tunnel`; callers should close the
    /// resulting network rather than closing the tunnel independently.
    ///
    /// - Parameters:
    ///   - tunnel: Negotiated Lockdown CoreDevice packet tunnel.
    ///   - connectionTimeout: Maximum duration for each device TCP handshake.
    /// - Throws: Configuration or network-backend initialization errors.
    public init(
        tunnel: CoreDeviceTunnel,
        connectionTimeout: Duration = .seconds(8)
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
                self?.close(after: error)
            }
        }
        inboundTask = Task { [weak self, tunnel, stack] in
            do {
                while !Task.isCancelled {
                    let packet = try await tunnel.receivePacket()
                    try await stack.receivePacket(packet)
                }
            } catch {
                self?.close(after: error)
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
        close(after: nil)
    }

    /// Tears down the complete network after explicit closure or pump failure.
    private func close(after error: Error?) {
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
    }
}
