#if canImport(NIOPosix) && !os(WASI)
import Foundation
import NIOCore
import NIOPosix

/// Unix-domain socket implementation of `DeviceConnection` backed by SwiftNIO.
///
/// The local usbmux daemon is normally reached through a Unix-domain socket on
/// macOS and Linux. This wrapper keeps that transport available while sharing
/// the same NIO byte-stream adapter used by TCP connections.
public final class UnixDomainSocketConnection:
    DeviceConnection,
    StreamingDeviceConnection,
    NIOSecureSessionConnection
{
    /// Shared NIO byte stream used by the public connection wrapper.
    private let connection: NIODeviceConnection

    /// Creates a Unix-domain wrapper around an initialized NIO byte stream.
    init(connection: NIODeviceConnection) {
        self.connection = connection
    }

    /// Opens a Unix-domain socket connection.
    ///
    /// - Parameter path: Filesystem path to the socket, usually
    ///   `/var/run/usbmuxd`.
    /// - Returns: An open byte-stream connection.
    public static func connect(toSocketAt path: String) async throws -> UnixDomainSocketConnection {
        let bootstrap = ClientBootstrap(group: NIOTransportRuntime.eventLoopGroup)

        do {
            let asyncChannel = try await bootstrap.connect(unixDomainSocketPath: path) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel)
                }
            }
            let connection = NIODeviceConnection(asyncChannel: asyncChannel)
            return UnixDomainSocketConnection(connection: connection)
        } catch {
            throw RorkDeviceError.transport("connect failed: \(describeTransportError(error))")
        }
    }

    /// Sends all bytes in `data`.
    public func send(_ data: Data) async throws {
        try await connection.send(data)
    }

    /// Receives exactly `count` bytes unless the daemon closes the connection.
    public func receive(exactly count: Int) async throws -> Data {
        try await connection.receive(exactly: count)
    }

    /// Receives at least one byte and at most `count` bytes.
    public func receive(upTo count: Int) async throws -> Data {
        try await connection.receive(upTo: count)
    }

    /// Inserts client-authenticated TLS into the usbmux byte-stream channel.
    func startSecureSession(
        using configuration: NIOSecureSessionConfiguration
    ) async throws {
        try await connection.startSecureSession(using: configuration)
    }

    /// Closes the channel. Calling this more than once is safe.
    public func close() {
        connection.close()
    }
}
#endif
