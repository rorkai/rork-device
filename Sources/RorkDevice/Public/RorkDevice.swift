import Foundation

/// Package namespace for metadata that is useful to both the library and CLI.
///
/// `RorkDevice` intentionally has no instances. Use `DeviceClient` as the
/// high-level entry point for discovery, Lockdown sessions, and app-install
/// workflows.
public enum RorkDevice {
    /// Package version reported by APIs and command-line diagnostics.
    public static let version = "0.5.1"
}

/// High-level entry point for device discovery and service sessions.
///
/// `DeviceClient` supports two connection routes:
///
/// - authenticated Lockdown over usbmux or a direct endpoint, using an existing
///   pairing record;
/// - direct connections to service ports advertised by Remote Service
///   Discovery after a remote-pairing tunnel has been established.
///
/// Both routes return `DeviceSession`, so AFC staging, provisioning-profile
/// management, heartbeat, and InstallationProxy workflows do not depend on the
/// transport selected by the application.
public final class DeviceClient {
    /// Client used to discover devices and open usbmux-forwarded connections.
    private let usbmuxClient: USBMuxClient

    /// Strategy used when Lockdown requires a secure service connection.
    private let secureSessionUpgrader: SecureSessionUpgrader

    /// Creates a client with injectable transport and secure-session behavior.
    ///
    /// - Parameters:
    ///   - usbmuxClient: Client used for local usbmux discovery and forwarded
    ///     device-port connections.
    ///   - secureSessionUpgrader: Component responsible for upgrading
    ///     Lockdown and service connections when the device asks for secure
    ///     traffic. The default inserts SwiftNIO SSL into connections opened by
    ///     the package's built-in transports.
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

    /// Reads the Lockdown pairing record stored by the local usbmux daemon.
    ///
    /// This is the host credential created when the user trusted the computer.
    /// It is retrieved independently of device discovery, so callers may cache
    /// a discovered `Device` while still loading the latest stored pairing
    /// material immediately before opening a Lockdown session.
    ///
    /// - Parameter deviceIdentifier: Device UDID used as the usbmux record key.
    /// - Returns: Validated pairing material for the selected device.
    public func pairingRecord(
        for deviceIdentifier: String
    ) async throws -> PairingRecord {
        try await usbmuxClient.pairingRecord(for: deviceIdentifier)
    }

    /// Streams device attach and detach events from the local usbmux endpoint.
    ///
    /// Use this for watch-style tools that need to react to phones being
    /// connected or removed. Consumers can cancel iteration to close the
    /// underlying usbmux listen socket.
    ///
    /// - Returns: Async sequence of high-level device visibility events.
    public func deviceEvents() -> AsyncThrowingStream<DeviceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in usbmuxClient.deviceEvents() {
                        continuation.yield(DeviceEvent(event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
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

    /// Opens a live Remote Service Discovery session through an active tunnel.
    ///
    /// The method connects to the tunnel's negotiated discovery port, completes
    /// the HTTP/2 and RemoteXPC handshake, and builds a service directory from
    /// the device's current advertisement. It retains the discovery connection
    /// inside the returned session so those advertised ports remain valid while
    /// AFC, MISAgent, and InstallationProxy connections are opened.
    ///
    /// The caller remains responsible for retaining the packet tunnel itself.
    /// Closing or replacing that tunnel invalidates both the discovery channel
    /// and every service port returned by the advertisement.
    ///
    /// - Parameters:
    ///   - host: Device-side IPv6 address reachable through the packet tunnel.
    ///   - port: Remote Service Discovery port negotiated for that tunnel.
    ///   - label: Client label included in each service check-in request.
    /// - Returns: A session backed by the device's live RSD advertisement.
    /// - Throws: Transport failures while opening the discovery endpoint, or
    ///   `RorkDeviceError.protocolViolation` when the HTTP/2, RemoteXPC, or RSD
    ///   handshake is malformed.
    public func connect(
        toRemoteServicesAt host: String,
        port: UInt16,
        label: String = "rorkdevice"
    ) async throws -> DeviceSession {
        let connection: DeviceConnection
        do {
            connection = try await TCPDeviceConnection.connect(
                to: host,
                port: port
            )
        } catch {
            throw RorkDeviceError.transport(
                "Failed to connect Remote Service Discovery on \(host):\(port): \(describeDeviceSessionError(error))"
            )
        }

        let discoverySession = try await RemoteServiceDiscoverySession.open(
            over: connection
        )
        return DeviceSession(
            backend: RemoteServiceSessionBackend(
                host: host,
                directory: discoverySession.directory,
                label: label,
                retaining: discoverySession
            )
        )
    }

    /// Opens a live Remote Service Discovery session through a device transport.
    ///
    /// Use this overload when an embedded userspace network or another
    /// transport already knows how to reach device-side ports. Discovery and
    /// every advertised service connection use the same transport, so callers
    /// do not need to expose the device's private IPv6 address through the host
    /// network stack.
    ///
    /// The returned session retains the discovery connection that owns the
    /// advertised service ports. The caller must retain and eventually close
    /// the supplied transport's underlying tunnel or network for at least as
    /// long as the session is in use.
    ///
    /// - Parameters:
    ///   - transport: Route capable of opening device-side TCP service ports.
    ///   - discoveryPort: Remote Service Discovery port negotiated for the
    ///     active tunnel.
    ///   - label: Client label included in each service check-in request.
    /// - Returns: A session backed by the device's live RSD advertisement.
    /// - Throws: Transport failures while opening discovery or advertised
    ///   services, plus malformed HTTP/2, RemoteXPC, or RSD protocol errors.
    public func connect(
        toRemoteServicesUsing transport: any DeviceTransport,
        discoveryPort: UInt16,
        label: String = "rorkdevice"
    ) async throws -> DeviceSession {
        guard discoveryPort > 0 else {
            throw RorkDeviceError.invalidInput(
                "Remote Service Discovery requires a nonzero port."
            )
        }

        let connection: DeviceConnection
        do {
            connection = try await transport.connect(
                to: discoveryPort
            )
        } catch {
            throw RorkDeviceError.transport(
                "Failed to connect Remote Service Discovery through the supplied transport on port \(discoveryPort): \(describeDeviceSessionError(error))"
            )
        }

        let discoverySession = try await RemoteServiceDiscoverySession.open(
            over: connection
        )
        return DeviceSession(
            backend: RemoteServiceSessionBackend(
                transport: transport,
                directory: discoverySession.directory,
                label: label,
                retaining: discoverySession
            )
        )
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

private extension DeviceEvent {
    /// Converts the usbmux protocol event into the transport-neutral public model.
    init(_ event: USBMuxDeviceEvent) {
        switch event {
        case .attached(let device):
            self = .attached(Device(
                identifier: device.serialNumber,
                connection: .usbmux(deviceID: device.deviceID),
                properties: device.properties
            ))
        case .detached(let deviceID, let serialNumber):
            self = .detached(identifier: serialNumber, connection: .usbmux(deviceID: deviceID))
        }
    }
}
