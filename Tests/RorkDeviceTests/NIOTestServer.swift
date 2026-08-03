import Foundation
import NIOCore
import NIOPosix
@testable import RorkDevice

final class NIOTestServer: @unchecked Sendable {
    let port: UInt16

    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let lock = NSLock()
    private var stopped = false

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
