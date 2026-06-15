import Foundation

/// Service ports advertised by one live Remote Service Discovery session.
///
/// The directory is intentionally internal because its ports are valid only
/// while the discovery connection that produced it remains open. Public callers
/// receive a `DeviceSession`, which retains that connection and prevents stale
/// service maps from escaping independently.
struct RemoteServiceDirectory: Equatable, Sendable {
    /// Device identifier advertised by the discovery handshake, when available.
    ///
    /// This becomes the `UniqueDeviceID` returned by remote-session device info.
    let deviceIdentifier: String?

    /// Service names and TCP ports advertised by the active discovery session.
    ///
    /// These ports must not outlive the discovery session that produced them.
    let services: [String: UInt16]

    /// Creates a directory from a validated live discovery advertisement.
    init(deviceIdentifier: String?, services: [String: UInt16]) {
        self.deviceIdentifier = deviceIdentifier
        self.services = services
    }

    /// Resolves a Lockdown service name to its advertised remote port.
    ///
    /// Exact matches take precedence. When no exact entry exists, the lookup
    /// appends `.shim.remote`, allowing callers to use the same service names
    /// accepted by `DeviceSession.startService`.
    ///
    /// - Parameter serviceName: Exact advertised name or Lockdown service name.
    /// - Returns: Advertised port, or `nil` when the service is unavailable.
    func port(for serviceName: String) -> UInt16? {
        if let port = services[serviceName] {
            return port
        }
        return services["\(serviceName).shim.remote"]
    }
}
