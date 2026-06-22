#if canImport(NIOPosix)
import NIOPosix

/// Shared SwiftNIO runtime used by socket-backed device connections.
///
/// Device workflows usually open several short-lived service streams in one
/// logical operation: Lockdown, AFC, InstallationProxy, heartbeat, and MISAgent
/// can all appear in sequence. Keeping the event-loop group alive for the
/// package lifetime avoids shutting down NIO between those streams while still
/// letting each connection close its own channel promptly.
enum NIOTransportRuntime {
    /// Event loops used for TCP and Unix-domain socket client channels.
    static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}
#endif
