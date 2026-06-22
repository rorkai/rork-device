#if canImport(NIOPosix)
import Foundation

/// Transport for workflows that already know the device host endpoint.
///
/// Direct transports are useful for tunnels, test servers, and environments
/// that expose Lockdown without the local usbmux daemon. The Lockdown port can
/// be remapped while service ports are connected directly on the same host.
public struct DirectLockdownTransport: DeviceTransport {
    private let host: String
    private let lockdownPort: UInt16
    private let serviceConnectionTimeout: Duration
    private let serviceConnectionRetryDelay: Duration

    /// Creates a direct endpoint transport.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address used for all service connections.
    ///   - lockdownPort: Port that should be used when callers request the
    ///     standard Lockdown port `62078`.
    ///   - serviceConnectionTimeout: Timeout for each direct service-port
    ///     connection attempt.
    ///   - serviceConnectionRetryDelay: Delay before retrying a direct
    ///     service-port connection.
    public init(
        host: String,
        lockdownPort: UInt16 = 62078,
        serviceConnectionTimeout: Duration = .seconds(8),
        serviceConnectionRetryDelay: Duration = .milliseconds(150)
    ) {
        self.host = host
        self.lockdownPort = lockdownPort
        self.serviceConnectionTimeout = serviceConnectionTimeout
        self.serviceConnectionRetryDelay = serviceConnectionRetryDelay
    }

    /// Opens a connection to the requested service port on the direct host.
    ///
    /// The port reported by Lockdown is tried first. If that direct connection
    /// is refused, the transport also tries the byte-swapped value. That second
    /// attempt covers tunnel environments that expose service sockets using the
    /// same normalized port shape normally carried inside usbmux `Connect`
    /// packets, while keeping the normal direct-network path as the default.
    public func connect(to port: UInt16) async throws -> DeviceConnection {
        if port == 62078 {
            return try await TCPDeviceConnection.connect(
                to: host,
                port: lockdownPort,
                timeout: serviceConnectionTimeout
            )
        }

        var attempts: [DirectServicePortAttempt] = [
            DirectServicePortAttempt(reason: "reported", port: port)
        ]
        let swappedPort = port.byteSwapped
        if swappedPort != port {
            attempts.append(DirectServicePortAttempt(reason: "byte-swapped", port: swappedPort))
        }

        var errors: [String] = []
        for (index, attempt) in attempts.enumerated() {
            do {
                return try await TCPDeviceConnection.connect(
                    to: host,
                    port: attempt.port,
                    timeout: serviceConnectionTimeout
                )
            } catch {
                errors.append("\(attempt.reason)=\(attempt.port): \(describe(error))")
                let hasNextAttempt = index + 1 < attempts.count
                if hasNextAttempt, serviceConnectionRetryDelay != .zero {
                    try? await Task.sleep(for: serviceConnectionRetryDelay)
                }
            }
        }

        throw RorkDeviceError.transport(
            "Direct service connection failed for \(host), service port \(port), attempts: \(errors.joined(separator: "; "))."
        )
    }
}

private struct DirectServicePortAttempt {
    let reason: String
    let port: UInt16
}

private func describe(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    return error.localizedDescription
}
#endif
