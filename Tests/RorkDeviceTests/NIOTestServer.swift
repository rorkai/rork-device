import Foundation
import NIOCore
import NIOPosix
@testable import RorkDevice

/// Ephemeral loopback server backed by one dedicated event loop.
///
/// Tests must call `stop()` so the listener closes and its event-loop thread
/// joins before bundle teardown.
final class NIOTestServer: @unchecked Sendable {
    /// Ephemeral port assigned by the operating system.
    let port: UInt16

    /// Dedicated event loop that owns the listener and accepted channels.
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    /// Listening channel retained until explicit teardown.
    private let channel: Channel

    /// Serializes idempotent shutdown across test cleanup paths.
    private let lock = NSLock()

    /// Whether listener and event-loop teardown has already run.
    private var stopped = false

    /// Binds on loopback and installs the supplied child pipeline initializer.
    init(
        channelInitializer:
            @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var startedChannel: Channel?
        do {
            let channel = try ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(
                    .socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelInitializer(channelInitializer)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            startedChannel = channel
            guard
                let boundPort = channel.localAddress?.port,
                let port = UInt16(exactly: boundPort)
            else {
                throw RorkDeviceError.transport(
                    "Test server did not receive a valid local port."
                )
            }
            self.eventLoopGroup = eventLoopGroup
            self.channel = channel
            self.port = port
        } catch {
            try? startedChannel?.close().wait()
            try? eventLoopGroup.syncShutdownGracefully()
            throw error
        }
    }

    /// Closes the listener and synchronously joins the event loop once.
    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else {
                return false
            }
            stopped = true
            return true
        }
        guard shouldStop else {
            return
        }
        try? channel.close().wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }
}
