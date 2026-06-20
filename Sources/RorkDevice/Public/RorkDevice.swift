import Foundation

/// Package namespace for metadata that is useful to both the library and CLI.
///
/// `RorkDevice` intentionally has no instances. Use `DeviceClient` as the
/// high-level entry point for discovery, Lockdown sessions, and app-install
/// workflows.
public enum RorkDevice {
    /// Package version reported by APIs and command-line diagnostics.
    public static let version = "0.8.1"
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

    /// Establishes Lockdown trust and saves the accepted host pairing record.
    ///
    /// This method owns the complete USB pairing transaction: it reads the
    /// host BUID and device public key, creates one host identity, presents that
    /// identity to Lockdown, and saves the accepted record through usbmux. If
    /// iOS is waiting for the Trust dialog, the same identity is retried over
    /// fresh Lockdown connections until the user responds or `trustTimeout`
    /// expires.
    ///
    /// Reusing one identity is essential. Generating a new identity for every
    /// retry would create repeated Trust prompts and could never confirm the
    /// identity the user actually approved.
    ///
    /// - Parameters:
    ///   - device: USB-backed device returned by `discoverDevices()`.
    ///   - trustTimeout: Maximum time to wait for the device-side decision.
    ///   - retryInterval: Delay between checks while the Trust dialog remains
    ///     unanswered. Zero is accepted for deterministic tests.
    ///   - onProgress: Optional callback for user-facing pairing state.
    /// - Returns: Completed pairing material, including the device-issued
    ///   escrow bag, after it has been saved by usbmux.
    /// - Throws: `LockdownPairingError` for user decisions and timeout,
    ///   `RorkDeviceError.invalidInput` for unsupported routes, or underlying
    ///   transport and certificate errors.
    public func pair(
        with device: Device,
        trustTimeout: Duration = .seconds(120),
        retryInterval: Duration = .seconds(1),
        onProgress: (@Sendable (DevicePairingProgress) -> Void)? = nil
    ) async throws -> PairingRecord {
        guard trustTimeout >= .zero else {
            throw RorkDeviceError.invalidInput(
                "Pairing trust timeout cannot be negative."
            )
        }
        guard retryInterval >= .zero else {
            throw RorkDeviceError.invalidInput(
                "Pairing retry interval cannot be negative."
            )
        }
        guard case let .usbmux(deviceID) = device.connection else {
            throw RorkDeviceError.invalidInput(
                "Lockdown pairing requires a usbmux device."
            )
        }

        let transport = USBMuxDeviceTransport(
            deviceID: deviceID,
            usbmuxClient: usbmuxClient
        )
        let prerequisites = try await pairingPrerequisites(
            using: transport
        )
        let candidate = try LockdownPairingMaterial.generate(
            deviceIdentifier: device.identifier,
            systemBUID: try await usbmuxClient.systemBUID(),
            devicePublicKey: prerequisites.devicePublicKey,
            wiFiMACAddress: prerequisites.wiFiMACAddress
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: trustTimeout)
        var reportedWaiting = false
        while true {
            try Task.checkCancellation()
            do {
                let escrowBag = try await requestPairing(
                    candidate,
                    using: transport
                )
                let acceptedRecord = try candidate.addingEscrowBag(
                    escrowBag
                )
                onProgress?(.savingPairingRecord)
                try await usbmuxClient.savePairingRecord(acceptedRecord)
                return acceptedRecord
            } catch LockdownPairingError.userConfirmationRequired {
                if !reportedWaiting {
                    onProgress?(.waitingForUserConfirmation)
                    reportedWaiting = true
                }
                let now = clock.now
                guard now < deadline else {
                    throw LockdownPairingError.timedOut
                }
                try await clock.sleep(
                    for: min(
                        retryInterval,
                        now.duration(to: deadline)
                    )
                )
            }
        }
    }

    /// Removes Lockdown trust between the host and a usbmux-backed device.
    ///
    /// The device-side identity is revoked first. Only after Lockdown confirms
    /// that request does the method remove the corresponding pairing record
    /// from local usbmux storage. This ordering avoids discarding the host
    /// credentials while the device may still trust them.
    ///
    /// If usbmux cannot remove the local record after the device has accepted
    /// `Unpair`, the storage error is propagated and the stale host record
    /// remains available for explicit cleanup through `USBMuxClient`.
    ///
    /// - Parameter device: usbmux-backed device returned by
    ///   `discoverDevices()`.
    /// - Throws: `RorkDeviceError.invalidInput` for unsupported routes,
    ///   pairing-record errors, Lockdown rejection, or a usbmux removal error.
    public func unpair(
        from device: Device
    ) async throws {
        guard case let .usbmux(deviceID) = device.connection else {
            throw RorkDeviceError.invalidInput(
                "Lockdown unpairing requires a usbmux device."
            )
        }
        let pairingRecord = try await usbmuxClient.pairingRecord(
            for: device.identifier
        )
        let transport = USBMuxDeviceTransport(
            deviceID: deviceID,
            usbmuxClient: usbmuxClient
        )
        try await requestUnpairing(
            pairingRecord,
            using: transport
        )
        try await usbmuxClient.removePairingRecord(
            for: device.identifier
        )
    }

    /// Streams device attach and detach events from the local usbmux endpoint.
    ///
    /// Use this for watch-style tools that need to react to phones being
    /// connected or removed. Consumers can cancel iteration to close the
    /// underlying usbmux listen socket.
    ///
    /// - Returns: Async sequence of high-level device visibility events.
    public func deviceEvents() -> AsyncThrowingStream<DeviceEvent, Error> {
        let usbmuxClient = self.usbmuxClient
        return AsyncThrowingStream { continuation in
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

    /// Reads device fields required before host certificates can be generated.
    private func pairingPrerequisites(
        using transport: DeviceTransport
    ) async throws -> LockdownPairingPrerequisites {
        let connection = try await transport.connect(to: 62078)
        defer {
            connection.close()
        }
        let lockdown = LockdownClient(connection: connection)
        guard let devicePublicKey = try await lockdown.value(
            domain: nil,
            key: "DevicePublicKey"
        ) as? Data,
              !devicePublicKey.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown DevicePublicKey was missing or empty."
            )
        }
        guard let wiFiMACAddress = try await lockdown.value(
            domain: nil,
            key: "WiFiAddress"
        ) as? String else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown WiFiAddress was missing."
            )
        }
        return LockdownPairingPrerequisites(
            devicePublicKey: devicePublicKey,
            wiFiMACAddress: wiFiMACAddress
        )
    }

    /// Performs one Pair request over a disposable Lockdown connection.
    ///
    /// Lockdown commonly closes the pairing connection while the device-side
    /// dialog is pending. A fresh connection per attempt avoids coupling later
    /// retries to that transport lifecycle.
    private func requestPairing(
        _ pairingRecord: PairingRecord,
        using transport: DeviceTransport
    ) async throws -> Data {
        let connection = try await transport.connect(to: 62078)
        defer {
            connection.close()
        }
        return try await LockdownClient(
            connection: connection
        ).pair(using: pairingRecord)
    }

    /// Performs one device-side Unpair request over a disposable connection.
    ///
    /// The caller removes local pairing material only after this method
    /// returns. Keeping the transport lifecycle here makes that ordering
    /// explicit and ensures the Lockdown connection closes on every outcome.
    private func requestUnpairing(
        _ pairingRecord: PairingRecord,
        using transport: DeviceTransport
    ) async throws {
        let connection = try await transport.connect(to: 62078)
        defer {
            connection.close()
        }
        try await LockdownClient(
            connection: connection
        ).unpair(using: pairingRecord)
    }
}

/// User-visible milestones emitted while a host establishes Lockdown trust.
public enum DevicePairingProgress: Equatable, Sendable {
    /// iOS has displayed a Trust dialog and is waiting for the user's decision.
    case waitingForUserConfirmation

    /// Lockdown accepted the identity and usbmux is persisting the completed
    /// pairing record.
    case savingPairingRecord
}

/// Device values that must be read before generating pairing certificates.
private struct LockdownPairingPrerequisites {
    /// RSA public key that the pairing root must bind to this device.
    let devicePublicKey: Data

    /// Wi-Fi hardware address stored in the completed pairing record.
    let wiFiMACAddress: String
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
