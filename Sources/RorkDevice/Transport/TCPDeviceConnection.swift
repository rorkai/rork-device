import Foundation
import NIOCore
import NIOPosix

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
        let handler = NIOByteStreamHandler()
        var bootstrap = ClientBootstrap(group: NIOTransportRuntime.eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        if let timeout {
            bootstrap = bootstrap.connectTimeout(timeout.nioTimeAmount)
        }

        do {
            let channel = try await bootstrap.connect(host: host, port: Int(port)).get()
            let connection = NIODeviceConnection(
                channel: channel,
                handler: handler
            )
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
