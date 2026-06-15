import Foundation
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#endif

/// TCP implementation of `DeviceConnection` backed by SwiftNIO.
///
/// TCP is used for direct Lockdown endpoints, tunnel-backed service ports, and
/// test daemons. The public API remains a small async byte stream while NIO
/// handles DNS resolution, non-blocking connect, read readiness, and writes.
public final class TCPDeviceConnection: DeviceConnection, PartialReceiveDeviceConnection {
    /// Shared NIO byte stream used by the public connection wrapper.
    private let connection: NIODeviceConnection

    /// Creates a TCP wrapper around an initialized NIO byte stream.
    init(connection: NIODeviceConnection) {
        self.connection = connection
    }

    /// Opens a TCP connection to a host and port.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address to resolve.
    ///   - port: TCP port in host byte order.
    ///   - timeout: Optional connection timeout. When omitted, SwiftNIO's
    ///     default connect timeout is used.
    /// - Returns: An open connection that reads and writes byte buffers.
    public static func connect(
        to host: String,
        port: UInt16,
        timeout: Duration? = nil
    ) async throws -> TCPDeviceConnection {
        try await connect(
            to: host,
            port: port,
            bootstrap: makeBootstrap(timeout: timeout)
        )
    }

    #if canImport(Darwin)
    /// Opens a TCP connection whose IPv4 route is bound to one interface index.
    ///
    /// Darwin exposes `IP_BOUND_IF`, which the packet-tunnel integration uses
    /// to keep provider-originated traffic on its virtual interface. Other
    /// platforms retain the general TCP API without exposing this Apple socket
    /// option.
    static func connect(
        to host: String,
        port: UInt16,
        boundToIPv4Interface interfaceIndex: UInt32,
        timeout: Duration? = nil
    ) async throws -> TCPDeviceConnection {
        guard interfaceIndex > 0,
              let socketInterfaceIndex = CInt(exactly: interfaceIndex) else {
            throw RorkDeviceError.invalidInput(
                "IPv4 interface index \(interfaceIndex) is not a valid socket interface index."
            )
        }

        let bootstrap = makeBootstrap(timeout: timeout).channelOption(
            .socket(IPPROTO_IP, IP_BOUND_IF),
            value: socketInterfaceIndex
        )
        return try await connect(to: host, port: port, bootstrap: bootstrap)
    }
    #endif

    /// Creates the shared NIO bootstrap and applies an optional connect timeout.
    private static func makeBootstrap(timeout: Duration?) -> ClientBootstrap {
        let bootstrap = ClientBootstrap(group: NIOTransportRuntime.eventLoopGroup)
        guard let timeout else {
            return bootstrap
        }
        return bootstrap.connectTimeout(timeout.nioTimeAmount)
    }

    /// Opens and wraps an NIO channel using a prepared bootstrap.
    private static func connect(
        to host: String,
        port: UInt16,
        bootstrap: ClientBootstrap
    ) async throws -> TCPDeviceConnection {
        do {
            let asyncChannel = try await bootstrap.connect(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
            let connection = NIODeviceConnection(asyncChannel: asyncChannel)
            return TCPDeviceConnection(connection: connection)
        } catch {
            throw RorkDeviceError.transport("connect failed: \(describeTransportError(error))")
        }
    }

    /// Sends all bytes in `data`.
    public func send(_ data: Data) async throws {
        try await connection.send(data)
    }

    /// Receives exactly `count` bytes unless the connection closes first.
    public func receive(exactly count: Int) async throws -> Data {
        try await connection.receive(exactly: count)
    }

    /// Receives at least one byte and at most `count` bytes.
    func receive(upTo count: Int) async throws -> Data {
        try await connection.receive(upTo: count)
    }

    /// Closes the channel. Calling this more than once is safe.
    public func close() {
        connection.close()
    }
}

private extension Duration {
    /// Converts Swift's `Duration` into the nanosecond timeout type used by NIO.
    var nioTimeAmount: TimeAmount {
        let parts = components
        let seconds = Double(parts.seconds)
        let attoseconds = Double(parts.attoseconds)
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        let clampedNanoseconds = max(1, min(nanoseconds, Double(Int64.max)))
        return .nanoseconds(Int64(clampedNanoseconds))
    }
}
