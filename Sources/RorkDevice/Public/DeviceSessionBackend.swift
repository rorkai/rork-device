import Foundation

/// Transport-specific operations required by the high-level `DeviceSession`.
///
/// Backends preserve the same service-oriented API while obtaining endpoints
/// either from Lockdown or from a live Remote Service Discovery advertisement.
protocol DeviceSessionBackend {
    /// Returns the device information available through this transport.
    func fetchDeviceInfo() async throws -> DeviceInfo

    /// Reads whether Developer Mode is enabled when the backend exposes the
    /// Lockdown AMFI value domain.
    func isDeveloperModeEnabled() async throws -> Bool

    /// Enables host connections through the device's wireless Lockdown route.
    func enableWirelessConnections() async throws

    /// Opens a service stream that is ready for its service-specific protocol.
    func startService(named serviceName: String, escrowBag: Data?) async throws -> DeviceConnection

    /// Opens a raw service advertised directly by Remote Service Discovery.
    ///
    /// Unlike Lockdown-compatible shim services, direct CoreDevice services do
    /// not exchange `RSDCheckin` property lists before their own protocol
    /// begins.
    func startRemoteService(named serviceName: String) async throws -> DeviceConnection
}

extension DeviceSessionBackend {
    /// Remote Service Discovery does not expose Lockdown value domains.
    func isDeveloperModeEnabled() async throws -> Bool {
        throw RorkDeviceError.protocolViolation(
            "Developer Mode status requires a Lockdown session."
        )
    }

    /// Rejects wireless Lockdown configuration for non-Lockdown backends.
    func enableWirelessConnections() async throws {
        throw RorkDeviceError.protocolViolation(
            "Wireless connections can only be configured through a Lockdown session."
        )
    }

    /// Rejects direct Remote Service Discovery access for non-RSD backends.
    func startRemoteService(named serviceName: String) async throws -> DeviceConnection {
        throw RorkDeviceError.protocolViolation(
            "Remote service \(serviceName) requires a Remote Service Discovery session."
        )
    }
}

/// Starts services through an authenticated Lockdown session.
final class LockdownDeviceSessionBackend: DeviceSessionBackend {
    /// Transport used to connect to ports returned by Lockdown.
    private let transport: DeviceTransport

    /// Authenticated Lockdown client used to request service endpoints.
    private let lockdown: LockdownClient

    /// Pairing credentials used when a service requests secure transport.
    private let pairingRecord: PairingRecord

    /// Component that upgrades service streams requiring encryption.
    private let secureSessionUpgrader: SecureSessionUpgrader

    /// Creates a backend around an established Lockdown session.
    init(
        transport: DeviceTransport,
        lockdown: LockdownClient,
        pairingRecord: PairingRecord,
        secureSessionUpgrader: SecureSessionUpgrader
    ) {
        self.transport = transport
        self.lockdown = lockdown
        self.pairingRecord = pairingRecord
        self.secureSessionUpgrader = secureSessionUpgrader
    }

    /// Reads the default Lockdown value domain into the public device model.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: try await lockdown.deviceValues())
    }

    /// Reads Developer Mode from Lockdown's AMFI value domain.
    func isDeveloperModeEnabled() async throws -> Bool {
        try await lockdown.developerModeStatus()
    }

    /// Enables the wireless Lockdown route used by local device tunnels.
    func enableWirelessConnections() async throws {
        try await lockdown.setValue(
            true,
            domain: "com.apple.mobile.wireless_lockdown",
            key: "EnableWifiConnections"
        )
    }

    /// Requests a service from Lockdown and returns a protocol-ready stream.
    ///
    /// The backend owns the raw service connection until a required secure
    /// upgrade succeeds. If the upgrader throws, the raw connection is closed
    /// before the error is propagated.
    func startService(named serviceName: String, escrowBag: Data?) async throws -> DeviceConnection {
        let service = try await lockdown.startService(serviceName, escrowBag: escrowBag)
        var connection: DeviceConnection
        do {
            connection = try await transport.connect(to: service.port)
        } catch {
            throw RorkDeviceError.transport(
                "Failed to connect \(service.name) on service port \(service.port): \(describeDeviceSessionError(error))"
            )
        }
        if service.requiresSecureConnection {
            do {
                connection = try await secureSessionUpgrader.upgrade(
                    connection,
                    pairingRecord: pairingRecord
                )
            } catch {
                connection.close()
                throw error
            }
        }
        return connection
    }
}

/// Produces a stable diagnostic string without discarding `RorkDeviceError` context.
func describeDeviceSessionError(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    return error.localizedDescription
}
