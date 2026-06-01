import Foundation

/// Transport for workflows that already know the device host endpoint.
///
/// Direct transports are useful for tunnels, test servers, and environments
/// that expose Lockdown without the local usbmux daemon. The Lockdown port can
/// be remapped while service ports are connected directly on the same host.
public struct DirectLockdownTransport: DeviceTransport {
    private let host: String
    private let lockdownPort: UInt16

    /// Creates a direct endpoint transport.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address used for all service connections.
    ///   - lockdownPort: Port that should be used when callers request the
    ///     standard Lockdown port `62078`.
    public init(host: String, lockdownPort: UInt16 = 62078) {
        self.host = host
        self.lockdownPort = lockdownPort
    }

    /// Opens a connection to the requested service port on the direct host.
    public func connect(to port: UInt16) async throws -> DeviceConnection {
        try await TCPDeviceConnection.connect(host: host, port: port == 62078 ? lockdownPort : port)
    }
}
