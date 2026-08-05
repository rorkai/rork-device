#if canImport(NIOPosix) && canImport(RorkDeviceLwIP) && !os(WASI)
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
#if os(Windows)
import WinSDK
#endif

/// Loopback TCP gateway for services reachable through a CoreDevice userspace network.
///
/// Existing device tooling commonly selects a destination by opening a local
/// TCP connection and sending a 20-byte preamble. It contains the device's
/// 16-byte IPv6 address followed by a little-endian 32-bit port. This gateway
/// accepts that protocol and forwards each connection through
/// `CoreDeviceUserspaceNetwork`.
///
/// The listener binds only to the host requested by the caller. Applications
/// should normally keep the default loopback address because the preamble has
/// no authentication and grants access to services exposed by the paired
/// device for the lifetime of the underlying tunnel.
///
/// Call `close()` and then await `waitUntilClosed()` when deterministic teardown
/// matters. Deallocation only initiates the same nonblocking close sequence.
public final class CoreDeviceUserspaceGateway: @unchecked Sendable {
    /// Host address on which the gateway accepts local clients.
    public let host: String

    /// Bound TCP port. When startup requests port zero, this is the ephemeral
    /// port selected by the operating system.
    public let port: UInt16

    /// Device IPv6 address accepted in client preambles.
    public let deviceAddress: String

    /// Network retained and closed by gateways created through the public API.
    private let ownedNetwork: CoreDeviceUserspaceNetwork?

    /// Server channel that owns the listening socket.
    private let server: any Channel

    /// Protects listener shutdown and access to the network monitor task.
    private let closeLock = NSLock()

    /// Task that closes the listener when the owned packet network terminates.
    private var networkMonitorTask: Task<Void, Never>?

    /// Preserves the owned network's terminal result until a waiter observes it.
    private let networkTermination = GatewayNetworkTermination()

    /// Tracks accepted channels so synchronous shutdown can close every stream.
    private let forwardingChannels: GatewayForwardingChannels

    /// Whether listener and network teardown has already begun.
    private var isClosed = false

    /// Creates a bound gateway around its listener and optional owned network.
    ///
    /// - Parameters:
    ///   - host: Local address on which the listener is bound.
    ///   - port: Actual listener port after an ephemeral bind is resolved.
    ///   - deviceAddress: Device IPv6 address accepted in client preambles.
    ///   - ownedNetwork: Network whose lifecycle belongs to this gateway.
    ///   - server: Bound listener channel that signals listener teardown.
    ///   - forwardingChannels: Registry that owns accepted channels until their
    ///     forwarding tasks finish.
    ///   - waitUntilNetworkCloses: Optional monitor for the owned network.
    private init(
        host: String,
        port: UInt16,
        deviceAddress: String,
        ownedNetwork: CoreDeviceUserspaceNetwork?,
        server: any Channel,
        forwardingChannels: GatewayForwardingChannels,
        waitUntilNetworkCloses: (@Sendable () async throws -> Void)?
    ) {
        self.host = host
        self.port = port
        self.deviceAddress = deviceAddress
        self.ownedNetwork = ownedNetwork
        self.server = server
        self.forwardingChannels = forwardingChannels

        if let waitUntilNetworkCloses {
            let networkTermination = self.networkTermination
            networkMonitorTask = Task {
                do {
                    try await waitUntilNetworkCloses()
                    guard !Task.isCancelled else {
                        return
                    }
                    networkTermination.finish(with: .success(()))
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    networkTermination.finish(with: .failure(error))
                }
                forwardingChannels.closeAll()
                server.close(promise: nil)
            }
        }
    }

    deinit {
        close()
    }

    /// Starts a loopback-compatible gateway for an active userspace network.
    ///
    /// The gateway takes lifecycle ownership of `network`. Closing the gateway
    /// closes the listener, all active forwarded streams, the userspace TCP/IP
    /// backend, and the underlying CoreDevice packet tunnel.
    ///
    /// - Parameters:
    ///   - network: Active CoreDevice userspace network to expose.
    ///   - host: Local address on which clients may connect.
    ///   - port: Requested local port, or zero for an ephemeral port.
    /// - Returns: A running gateway with its actual bound port.
    /// - Throws: Address validation or listener-bind failures.
    public static func start(
        network: CoreDeviceUserspaceNetwork,
        host: String = "127.0.0.1",
        port: UInt16 = 0
    ) async throws -> CoreDeviceUserspaceGateway {
        try await start(
            deviceAddress: network.configuration.deviceAddress,
            host: host,
            port: port,
            ownedNetwork: network,
            waitUntilNetworkCloses: {
                try await network.waitUntilClosed()
            },
            connectionFactory: { destinationPort in
                try await network.connect(to: destinationPort)
            }
        )
    }

    /// Waits until the gateway or its owned userspace network closes.
    ///
    /// Long-running command-line tools can await this method after publishing
    /// the gateway endpoint. Explicit `close()` completes the wait normally.
    /// Listener failures and terminal packet-network failures are rethrown.
    public func waitUntilClosed() async throws {
        do {
            try await server.closeFuture.get()
        } catch {
            if let networkResult = networkTermination.result {
                try networkResult.get()
                return
            }
            let closedExplicitly = closeLock.withLock { isClosed }
            guard closedExplicitly else {
                throw error
            }
        }
        if let networkResult = networkTermination.result {
            try networkResult.get()
        }
    }

    /// Stops accepting clients and closes the owned userspace network.
    ///
    /// Calling this method more than once is safe.
    public func close() {
        let state: (shouldClose: Bool, networkMonitor: Task<Void, Never>?) =
            closeLock.withLock {
                guard !isClosed else {
                    return (false, nil)
                }
                isClosed = true
                let networkMonitor = networkMonitorTask
                networkMonitorTask = nil
                return (true, networkMonitor)
            }
        guard state.shouldClose else {
            return
        }

        state.networkMonitor?.cancel()
        forwardingChannels.closeAll()
        server.close(promise: nil)
        ownedNetwork?.close()
    }

    /// Closes the gateway and waits for every forwarding scope to finish.
    func closeAndWait() async {
        close()
        _ = try? await server.closeFuture.get()
        await forwardingChannels.waitUntilEmpty()
    }

    /// Failure to start a gateway because its requested port is already bound.
    ///
    /// Callers that re-request a previous ephemeral port across restarts catch
    /// this to fall back to a fresh port. An invalid host and exhausted
    /// descriptors are not fixed by changing ports, so those failures keep
    /// their original error type.
    public struct PortUnavailableError: Error, CustomStringConvertible,
        LocalizedError
    {
        /// Host whose port could not be bound.
        public let host: String

        /// Requested port that is already in use.
        public let port: UInt16

        /// Human-readable description of the conflicting listener endpoint.
        public var description: String {
            "Local gateway port \(port) on \(host) is already in use."
        }

        /// Localized description presented by APIs that consume `LocalizedError`.
        public var errorDescription: String? {
            description
        }
    }

    /// Starts a gateway with injectable transport behavior for tests.
    ///
    /// `waitUntilNetworkCloses` models the owned packet network's terminal
    /// signal without requiring a physical tunnel or userspace TCP/IP stack. It
    /// returns after orderly shutdown and throws the failure that ended the
    /// network.
    ///
    /// - Parameters:
    ///   - deviceAddress: Device IPv6 address accepted by the preamble.
    ///   - host: Local address on which clients may connect.
    ///   - port: Requested local port, or zero for an ephemeral port.
    ///   - waitUntilNetworkCloses: Optional network-lifecycle signal.
    ///   - connectionFactory: Opens the requested device-side service.
    static func start(
        deviceAddress: String,
        host: String,
        port: UInt16,
        waitUntilNetworkCloses: (@Sendable () async throws -> Void)? = nil,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async throws -> CoreDeviceUserspaceGateway {
        try await start(
            deviceAddress: deviceAddress,
            host: host,
            port: port,
            ownedNetwork: nil,
            waitUntilNetworkCloses: waitUntilNetworkCloses,
            connectionFactory: connectionFactory
        )
    }

    /// Binds the listener after validating the expected device address.
    private static func start(
        deviceAddress: String,
        host: String,
        port: UInt16,
        ownedNetwork: CoreDeviceUserspaceNetwork?,
        waitUntilNetworkCloses: (@Sendable () async throws -> Void)?,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async throws -> CoreDeviceUserspaceGateway {
        let expectedDeviceAddress = try ipv6AddressBytes(
            deviceAddress,
            invalidMessage:
                "CoreDevice userspace gateway requires a valid device IPv6 address."
        )

        let forwardingChannels = GatewayForwardingChannels()
        let server: any Channel
        do {
            var bootstrap = ServerBootstrap(
                group: NIOTransportRuntime.eventLoopGroup
            )

            // Winsock defines SO_EXCLUSIVEADDRUSE as the bitwise complement of
            // SO_REUSEADDR. Enabling it prevents overlapping listeners and
            // keeps gateway port conflicts deterministic.
            #if os(Windows)
            bootstrap = bootstrap.serverChannelOption(
                .socketOption(
                    NIOBSDSocket.Option(
                        rawValue: ~CInt(SO_REUSEADDR)
                    )
                ),
                value: 1
            )
            #else
            bootstrap = bootstrap.serverChannelOption(
                .socketOption(.so_reuseaddr),
                value: 1
            )
            #endif
            bootstrap = bootstrap
                .childChannelOption(.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<
                            ByteBuffer,
                            Never
                        >(
                            wrappingChannelSynchronously: channel
                        )
                        guard forwardingChannels.register(channel) else {
                            return
                        }
                        _ = Task {
                            defer {
                                forwardingChannels.unregister(channel)
                            }
                            await serve(
                                asyncChannel,
                                expectedDeviceAddress: expectedDeviceAddress,
                                connectionFactory: connectionFactory
                            )
                        }
                    }
                }
            server = try await bootstrap.bind(
                host: host,
                port: Int(port)
            ).get()
        } catch let error as IOError where isAddressInUseError(error) {
            throw PortUnavailableError(host: host, port: port)
        }

        guard let boundPort = server.localAddress?.port,
            let gatewayPort = UInt16(exactly: boundPort)
        else {
            server.close(promise: nil)
            throw RorkDeviceError.transport(
                "CoreDevice userspace gateway did not receive a valid local port."
            )
        }

        return CoreDeviceUserspaceGateway(
            host: host,
            port: gatewayPort,
            deviceAddress: deviceAddress,
            ownedNetwork: ownedNetwork,
            server: server,
            forwardingChannels: forwardingChannels,
            waitUntilNetworkCloses: waitUntilNetworkCloses
        )
    }

    /// Validates one destination preamble and proxies the remaining byte stream.
    private static func serve(
        _ channel: NIOAsyncChannel<ByteBuffer, Never>,
        expectedDeviceAddress: Data,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async {
        do {
            try await channel.executeThenClose { inbound in
                var iterator = inbound.makeAsyncIterator()
                var pending = ByteBufferAllocator().buffer(capacity: 20)
                while pending.readableBytes < 20 {
                    guard var chunk = try await iterator.next() else {
                        throw RorkDeviceError.protocolViolation(
                            "CoreDevice userspace gateway client closed before sending its destination preamble."
                        )
                    }
                    pending.writeBuffer(&chunk)
                }

                guard let addressBytes = pending.readBytes(length: 16),
                    Data(addressBytes) == expectedDeviceAddress
                else {
                    throw RorkDeviceError.invalidInput(
                        "CoreDevice userspace gateway rejected a destination for another device address."
                    )
                }
                guard
                    let rawPort = pending.readInteger(
                        endianness: .little,
                        as: UInt32.self
                    ),
                    let destinationPort = UInt16(exactly: rawPort),
                    destinationPort > 0
                else {
                    throw RorkDeviceError.invalidInput(
                        "CoreDevice userspace gateway requires a destination port from 1 through 65535."
                    )
                }

                let openedConnection = try await connectionFactory(
                    destinationPort
                )
                guard
                    let connection =
                        openedConnection as? any StreamingDeviceConnection
                else {
                    openedConnection.close()
                    throw RorkDeviceError.transport(
                        "CoreDevice gateway requires a full-duplex connection with partial reads."
                    )
                }
                defer {
                    connection.close()
                }

                if let initialPayload = pending.readData(
                    length: pending.readableBytes
                ), !initialPayload.isEmpty {
                    try await connection.send(initialPayload)
                }

                let deviceToClient = Task {
                    defer {
                        channel.channel.close(promise: nil)
                    }
                    while !Task.isCancelled {
                        let data = try await connection.receive(
                            upTo: 64 * 1_024
                        )
                        guard !data.isEmpty else {
                            throw RorkDeviceError.protocolViolation(
                                "CoreDevice userspace gateway received an empty partial read."
                            )
                        }
                        var buffer = channel.channel.allocator.buffer(
                            capacity: data.count
                        )
                        buffer.writeBytes(data)
                        try await channel.channel.writeAndFlush(buffer).get()
                    }
                }

                do {
                    while var buffer = try await iterator.next() {
                        guard
                            let data = buffer.readData(
                                length: buffer.readableBytes
                            ), !data.isEmpty
                        else {
                            continue
                        }
                        try await connection.send(data)
                    }
                } catch {
                    connection.close()
                }

                connection.close()
                deviceToClient.cancel()
                _ = await deviceToClient.result
            }
        } catch {
            channel.channel.close(promise: nil)
        }
    }
}

/// Owns accepted channels until their forwarding scopes finish.
///
/// Listener shutdown is synchronous. The registry closes active streams and
/// lets callers wait until their forwarding tasks release every channel.
/// Its lock protects all mutable state shared by listener and forwarding tasks.
private final class GatewayForwardingChannels: @unchecked Sendable {
    /// Serializes registry mutation, shutdown, and waiter registration.
    private let lock = NSLock()

    /// Active accepted channels keyed by object identity.
    private var channels: [ObjectIdentifier: any Channel] = [:]

    /// Whether shutdown has begun and late channels must be rejected.
    private var isClosing = false

    /// Continuations resumed after the final active channel unregisters.
    private var emptyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Registers a channel unless gateway shutdown has already begun.
    ///
    /// A channel that arrives after shutdown is closed before this method
    /// returns `false`.
    func register(_ channel: any Channel) -> Bool {
        let didRegister = lock.withLock {
            guard !isClosing else {
                return false
            }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
        if !didRegister {
            channel.close(promise: nil)
        }
        return didRegister
    }

    /// Removes a finished channel and resumes waiters after the registry drains.
    func unregister(_ channel: any Channel) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _ = channels.removeValue(forKey: ObjectIdentifier(channel))
            guard channels.isEmpty else {
                return []
            }
            let waiters = emptyWaiters
            emptyWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Rejects future registrations and closes every active channel.
    func closeAll() {
        let active = lock.withLock {
            isClosing = true
            return Array(channels.values)
        }
        for channel in active {
            channel.close(promise: nil)
        }
    }

    /// Suspends until every registered forwarding task has released its channel.
    func waitUntilEmpty() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !channels.isEmpty else {
                    return true
                }
                emptyWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

/// One-shot storage for the userspace network monitor's terminal result.
///
/// The monitor publishes its result before closing the NIO listener. This lets
/// `waitUntilClosed()` distinguish orderly network shutdown from failure and
/// prefer that outcome over errors caused by closing the listener.
/// Its lock protects the one-shot result shared with the waiting caller.
private final class GatewayNetworkTermination: @unchecked Sendable {
    /// Protects terminal-result publication across monitor and waiter tasks.
    private let lock = NSLock()

    /// First result published by the network monitor.
    private var terminalResult: Result<Void, Error>?

    /// Thread-safe snapshot of the network monitor's terminal result.
    var result: Result<Void, Error>? {
        lock.withLock { terminalResult }
    }

    /// Publishes `result` unless the monitor has already reached a terminal state.
    func finish(with result: Result<Void, Error>) {
        lock.withLock {
            if terminalResult == nil {
                terminalResult = result
            }
        }
    }
}

/// Opens one device-side connection selected by a gateway preamble.
typealias CoreDeviceGatewayConnectionFactory =
    @Sendable (UInt16) async throws -> DeviceConnection
#endif
