import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix

/// Loopback TCP gateway for services reachable through a CoreDevice userspace network.
///
/// Existing device tooling commonly selects a destination by opening a local
/// TCP connection and sending a 20-byte preamble: the device's 16-byte IPv6
/// address followed by a little-endian 32-bit port. This gateway accepts that
/// protocol and forwards each connection through `CoreDeviceUserspaceNetwork`.
///
/// The listener binds only to the host requested by the caller. Applications
/// should normally keep the default loopback address because the preamble has
/// no authentication and grants access to services exposed by the paired
/// device for the lifetime of the underlying tunnel.
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

    /// Async server channel that owns the listening socket.
    private let server: NIOAsyncChannel<
        NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        Never
    >

    /// Protects listener shutdown and access to the accept-loop task.
    private let closeLock = NSLock()

    /// Long-lived task accepting clients until the gateway closes.
    private var acceptTask: Task<Void, Error>?

    /// Whether listener and network teardown has already begun.
    private var isClosed = false

    /// Creates a bound gateway around its listener and optional owned network.
    private init(
        host: String,
        port: UInt16,
        deviceAddress: String,
        expectedDeviceAddress: Data,
        ownedNetwork: CoreDeviceUserspaceNetwork?,
        server: NIOAsyncChannel<
            NIOAsyncChannel<ByteBuffer, ByteBuffer>,
            Never
        >,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) {
        self.host = host
        self.port = port
        self.deviceAddress = deviceAddress
        self.ownedNetwork = ownedNetwork
        self.server = server

        acceptTask = Task {
            try await Self.runAcceptLoop(
                server: server,
                expectedDeviceAddress: expectedDeviceAddress,
                connectionFactory: connectionFactory
            )
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
            ownedNetwork: network
        ) { destinationPort in
            try await network.connect(to: destinationPort)
        }
    }

    /// Waits until the listener closes or its accept loop fails.
    ///
    /// Long-running command-line tools can await this method after publishing
    /// the gateway endpoint. Explicit `close()` completes the wait normally;
    /// unexpected listener failures are rethrown.
    public func waitUntilClosed() async throws {
        let task = closeLock.withLock { acceptTask }
        try await task?.value
    }

    /// Stops accepting clients and closes the owned userspace network.
    ///
    /// Calling this method more than once is safe.
    public func close() {
        let task: Task<Void, Error>? = closeLock.withLock {
            guard !isClosed else {
                return nil
            }
            isClosed = true
            let task = acceptTask
            acceptTask = nil
            return task
        }
        guard let task else {
            return
        }

        task.cancel()
        server.channel.close(promise: nil)
        ownedNetwork?.close()
    }

    /// Starts a gateway with an injectable destination connector for tests.
    static func start(
        deviceAddress: String,
        host: String,
        port: UInt16,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async throws -> CoreDeviceUserspaceGateway {
        try await start(
            deviceAddress: deviceAddress,
            host: host,
            port: port,
            ownedNetwork: nil,
            connectionFactory: connectionFactory
        )
    }

    /// Binds the listener after validating the expected device address.
    private static func start(
        deviceAddress: String,
        host: String,
        port: UInt16,
        ownedNetwork: CoreDeviceUserspaceNetwork?,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async throws -> CoreDeviceUserspaceGateway {
        let expectedDeviceAddress = try ipv6AddressBytes(
            deviceAddress,
            invalidMessage:
                "CoreDevice userspace gateway requires a valid device IPv6 address."
        )

        let server: NIOAsyncChannel<
            NIOAsyncChannel<ByteBuffer, ByteBuffer>,
            Never
        > = try await ServerBootstrap(
            group: NIOTransportRuntime.eventLoopGroup
        )
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(.autoRead, value: true)
        .bind(host: host, port: Int(port)) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: channel
                )
            }
        }

        guard let boundPort = server.channel.localAddress?.port,
              let gatewayPort = UInt16(exactly: boundPort) else {
            server.channel.close(promise: nil)
            throw RorkDeviceError.transport(
                "CoreDevice userspace gateway did not receive a valid local port."
            )
        }

        return CoreDeviceUserspaceGateway(
            host: host,
            port: gatewayPort,
            deviceAddress: deviceAddress,
            expectedDeviceAddress: expectedDeviceAddress,
            ownedNetwork: ownedNetwork,
            server: server,
            connectionFactory: connectionFactory
        )
    }

    /// Accepts clients concurrently while keeping each forwarding failure local.
    private static func runAcceptLoop(
        server: NIOAsyncChannel<
            NIOAsyncChannel<ByteBuffer, ByteBuffer>,
            Never
        >,
        expectedDeviceAddress: Data,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async throws {
        try await server.executeThenClose { inbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await channel in inbound {
                    group.addTask {
                        await serve(
                            channel,
                            expectedDeviceAddress:
                                expectedDeviceAddress,
                            connectionFactory: connectionFactory
                        )
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    /// Validates one destination preamble and proxies the remaining byte stream.
    private static func serve(
        _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        expectedDeviceAddress: Data,
        connectionFactory: @escaping CoreDeviceGatewayConnectionFactory
    ) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
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
                      Data(addressBytes) == expectedDeviceAddress else {
                    throw RorkDeviceError.invalidInput(
                        "CoreDevice userspace gateway rejected a destination for another device address."
                    )
                }
                guard let rawPort = pending.readInteger(
                    endianness: .little,
                    as: UInt32.self
                ),
                let destinationPort = UInt16(exactly: rawPort),
                destinationPort > 0 else {
                    throw RorkDeviceError.invalidInput(
                        "CoreDevice userspace gateway requires a destination port from 1 through 65535."
                    )
                }

                let connection = try await connectionFactory(
                    destinationPort
                )
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
                    guard let partialConnection =
                        connection as? PartialReceiveDeviceConnection else {
                        throw RorkDeviceError.transport(
                            "CoreDevice userspace gateway requires a connection that supports partial reads."
                        )
                    }
                    while !Task.isCancelled {
                        let data = try await partialConnection.receive(
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
                        try await outbound.write(buffer)
                    }
                }

                do {
                    while var buffer = try await iterator.next() {
                        guard let data = buffer.readData(
                            length: buffer.readableBytes
                        ), !data.isEmpty else {
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

/// Opens one device-side connection selected by a gateway preamble.
typealias CoreDeviceGatewayConnectionFactory =
    @Sendable (UInt16) async throws -> DeviceConnection
