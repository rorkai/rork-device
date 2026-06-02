import Foundation

/// Package namespace for metadata that is useful to both the library and CLI.
///
/// `RorkDevice` intentionally has no instances. Use `DeviceClient` as the
/// high-level entry point for discovery, Lockdown sessions, and app-install
/// workflows.
public enum RorkDevice {
    /// Package version reported by APIs and command-line diagnostics.
    public static let version = "0.1.4"
}

/// High-level entry point for device discovery and authenticated sessions.
///
/// `DeviceClient` owns the top-level flow most callers need:
///
/// 1. Discover devices through the local usbmux daemon.
/// 2. Open Lockdown using an existing pairing record.
/// 3. Upgrade the connection when Lockdown requests secure traffic.
/// 4. Return a `DeviceSession` that can start AFC, MISAgent, and
///    InstallationProxy services.
///
/// The 0.1.0 API assumes the device is already paired. Pairing creation is kept
/// out of this first vertical slice so installation flows can be implemented and
/// tested against known pairing records first.
public final class DeviceClient {
    private let usbmuxClient: USBMuxClient
    private let secureSessionUpgrader: SecureSessionUpgrader

    /// Creates a client with injectable transport and secure-session behavior.
    ///
    /// - Parameters:
    ///   - usbmuxClient: Client used for local usbmux discovery and forwarded
    ///     device-port connections.
    ///   - secureSessionUpgrader: Component responsible for upgrading
    ///     Lockdown and service connections when the device asks for secure
    ///     traffic. The default uses the built-in Apple backend when Security
    ///     is available and otherwise throws `secureSessionUnsupported`.
    public init(
        usbmuxClient: USBMuxClient = USBMuxClient(),
        secureSessionUpgrader: SecureSessionUpgrader = DefaultSecureSessionUpgrader()
    ) {
        self.usbmuxClient = usbmuxClient
        self.secureSessionUpgrader = secureSessionUpgrader
    }

    /// Returns devices currently visible through the local usbmux endpoint.
    ///
    /// The returned values contain the stable device identifier and the usbmux
    /// device id needed to open a later Lockdown connection.
    ///
    /// - Throws: `RorkDeviceError.transport` when the usbmux socket cannot be
    ///   opened, or `RorkDeviceError.protocolViolation` when the daemon returns
    ///   malformed plist data.
    public func discoverDevices() async throws -> [Device] {
        try await usbmuxClient.listDevices().map { device in
            Device(
                identifier: device.serialNumber,
                connection: .usbmux(deviceID: device.deviceID),
                properties: device.properties
            )
        }
    }

    /// Opens an authenticated Lockdown session for a discovered device.
    ///
    /// The `pairingRecord` must belong to the same physical device. When
    /// Lockdown requests secure traffic, this method calls the configured
    /// `SecureSessionUpgrader` before returning the session.
    ///
    /// - Parameters:
    ///   - device: Device returned from `discoverDevices()` or created by a caller.
    ///   - pairingRecord: Existing Lockdown pairing record for the device.
    ///   - label: Client label sent in Lockdown requests for diagnostics.
    /// - Returns: A session that can query device information and start
    ///   developer services.
    /// - Throws: `RorkDeviceError.invalidPairingRecord`,
    ///   `RorkDeviceError.lockdown`, `RorkDeviceError.secureSessionUnsupported`,
    ///   or lower-level transport/protocol errors.
    public func connect(
        to device: Device,
        using pairingRecord: PairingRecord,
        label: String = "rorkdevice"
    ) async throws -> DeviceSession {
        switch device.connection {
        case let .usbmux(deviceID):
            let transport = USBMuxDeviceTransport(deviceID: deviceID, usbmuxClient: usbmuxClient)
            return try await openSession(transport: transport, pairingRecord: pairingRecord, label: label)
        case let .direct(host, port):
            return try await connect(to: host, port: port, using: pairingRecord, label: label)
        }
    }

    /// Opens an authenticated Lockdown session against a known endpoint.
    ///
    /// Use this when a tunnel, test harness, or embedded transport exposes the
    /// Lockdown port directly instead of relying on local usbmux discovery.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address that accepts Lockdown connections.
    ///   - port: Lockdown port. Defaults to `62078`, the standard Lockdown
    ///     service port.
    ///   - pairingRecord: Existing pairing record for the target device.
    ///   - label: Client label sent in Lockdown requests.
    /// - Returns: A `DeviceSession` backed by direct TCP connections.
    public func connect(
        to host: String,
        port: UInt16 = 62078,
        using pairingRecord: PairingRecord,
        label: String = "rorkdevice"
    ) async throws -> DeviceSession {
        let transport = DirectLockdownTransport(host: host, lockdownPort: port)
        return try await openSession(transport: transport, pairingRecord: pairingRecord, label: label)
    }

    /// Shared implementation for direct and usbmux-backed Lockdown sessions.
    private func openSession(
        transport: DeviceTransport,
        pairingRecord: PairingRecord,
        label: String
    ) async throws -> DeviceSession {
        var connection = try await transport.connect(to: 62078)
        let lockdown = LockdownClient(connection: connection, label: label)
        let session = try await lockdown.startSession(using: pairingRecord)
        if session.requiresSecureConnection {
            connection = try await secureSessionUpgrader.upgrade(connection, pairingRecord: pairingRecord)
        }

        return DeviceSession(
            transport: transport,
            lockdown: LockdownClient(connection: connection, label: label),
            pairingRecord: pairingRecord,
            label: label,
            secureSessionUpgrader: secureSessionUpgrader
        )
    }
}
