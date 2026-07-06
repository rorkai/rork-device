import Foundation

/// Package namespace for metadata that is useful to both the library and CLI.
///
/// `RorkDevice` intentionally has no instances. Use `DeviceClient` as the
/// high-level entry point for discovery, Lockdown sessions, and app-install
/// workflows.
public enum RorkDevice {
    /// Package version reported by APIs and command-line diagnostics.
    public static let version = "0.9.21"
}

/// Returns whether usbmux identifies a discovered device record as a USB route.
///
/// usbmux may publish USB and network records for the same UDID in unstable
/// order, so route selection must use `ConnectionType` instead of array order.
/// Missing or unrecognized connection metadata is treated as non-USB.
private func usesUSBRoute(_ device: Device) -> Bool {
    device.properties["ConnectionType"]?
        .caseInsensitiveCompare("USB") == .orderedSame
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
    #if canImport(NIOPosix) && !os(WASI)
    /// Client used to discover devices and open usbmux-forwarded connections.
    private let usbmuxClient: USBMuxClient
    #endif

    /// Strategy used when Lockdown requires a secure service connection.
    private let secureSessionUpgrader: SecureSessionUpgrader

    #if canImport(NIOPosix) && !os(WASI)
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
    #else
    /// Creates a client for caller-supplied device transports.
    ///
    /// Platforms without local socket support provide discovery and byte
    /// transport outside `RorkDevice`, then pass that transport to
    /// `connect(over:using:label:)`.
    ///
    /// - Parameter secureSessionUpgrader: Component responsible for upgrading
    ///   Lockdown and service connections when the device requests TLS.
    public init(
        secureSessionUpgrader: SecureSessionUpgrader = DefaultSecureSessionUpgrader()
    ) {
        self.secureSessionUpgrader = secureSessionUpgrader
    }
    #endif

    #if canImport(NIOPosix) && !os(WASI)
    /// Returns devices currently visible through the local usbmux endpoint.
    ///
    /// The returned values contain the stable device identifier and the usbmux
    /// device id needed to open a later Lockdown connection. The array
    /// preserves daemon order and every advertised route, so one physical
    /// device may appear more than once when both USB and network access are
    /// available. Use `discoverDevice(identifier:)` when only one preferred
    /// route is needed.
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

    /// Returns the preferred usbmux route for a device identifier.
    ///
    /// usbmux can advertise one physical device through USB and network at the
    /// same time. This method prefers USB because host pairing and Trust-prompt
    /// recovery require the cable route, then falls back to the first matching
    /// route so already-paired network access remains available without a
    /// cable.
    ///
    /// - Parameter identifier: Stable device identifier, normally the UDID.
    /// - Returns: The preferred matching route, or `nil` when usbmux does not
    ///   report the device.
    /// - Throws: `RorkDeviceError.transport` when the usbmux socket cannot be
    ///   opened, or `RorkDeviceError.protocolViolation` when the daemon returns
    ///   malformed plist data.
    public func discoverDevice(
        identifier: String
    ) async throws -> Device? {
        let matchingDevices = try await discoverDevices().filter {
            $0.identifier == identifier
        }
        if let usbDevice = matchingDevices.first(where: usesUSBRoute) {
            return usbDevice
        }
        return matchingDevices.first
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
    ///   - retryInterval: Positive delay between checks while the Trust dialog
    ///     remains unanswered.
    ///   - onProgress: Optional callback for user-facing pairing state.
    /// - Returns: Completed pairing material, including the device-issued
    ///   escrow bag, after it has been saved by usbmux.
    /// - Throws: `LockdownPairingError` for user decisions and timeout,
    ///   `RorkDeviceError.invalidInput` for unsupported routes, or underlying
    ///   transport and certificate errors.
    #if !os(WASI)
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
        guard retryInterval > .zero else {
            throw RorkDeviceError.invalidInput(
                "Pairing retry interval must be greater than zero."
            )
        }
        guard case .usbmux(let deviceID) = device.connection else {
            throw RorkDeviceError.invalidInput(
                "Lockdown pairing requires a usbmux device."
            )
        }

        let transport = USBMuxDeviceTransport(
            deviceID: deviceID,
            usbmuxClient: usbmuxClient
        )
        let pairingInformation = try await pairingInformation(
            over: transport
        )
        let candidate = try PairingRecord.candidate(
            for: pairingInformation,
            systemBUID: try await usbmuxClient.systemBUID()
        )

        let acceptedRecord = try await pair(
            using: candidate,
            over: transport,
            trustTimeout: trustTimeout,
            retryInterval: retryInterval,
            onProgress: onProgress
        )
        onProgress?(.savingPairingRecord)
        try await usbmuxClient.savePairingRecord(
            acceptedRecord,
            forDeviceID: deviceID
        )
        return acceptedRecord
    }
    #endif

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
        guard case .usbmux(let deviceID) = device.connection else {
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
    #endif

    #if canImport(NIOPosix) && !os(WASI)
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
        case .usbmux(let deviceID):
            let transport = USBMuxDeviceTransport(deviceID: deviceID, usbmuxClient: usbmuxClient)
            return try await connect(
                over: transport,
                using: pairingRecord,
                label: label
            )
        case .direct(let host, let port):
            return try await connect(to: host, port: port, using: pairingRecord, label: label)
        }
    }

    /// Reads a best-effort unauthenticated snapshot of a discovered device.
    ///
    /// Unlike `connect(to:using:label:)`, this opens no trusted session, so it
    /// still returns whatever identity, clock, and lock state the device exposes
    /// when a session cannot be established.
    ///
    /// - Parameter device: Device returned from `discoverDevices()`.
    /// - Returns: The values the device exposes without host trust.
    public func deviceEnvironment(
        for device: Device
    ) async throws -> DeviceEnvironment {
        switch device.connection {
        case .usbmux(let deviceID):
            return try await deviceEnvironment(
                over: USBMuxDeviceTransport(
                    deviceID: deviceID,
                    usbmuxClient: usbmuxClient
                )
            )
        case .direct(let host, let port):
            return try await deviceEnvironment(
                over: DirectLockdownTransport(
                    host: host,
                    lockdownPort: port
                )
            )
        }
    }
    #endif

    /// Opens an authenticated Lockdown session through a caller-supplied transport.
    ///
    /// Use this entry point when discovery and byte transport are provided by an
    /// embedding environment such as WebUSB. The transport must route port
    /// `62078` to Lockdown and continue routing later service ports for the
    /// lifetime of the returned session.
    ///
    /// - Parameters:
    ///   - transport: Route used for Lockdown and every service connection
    ///     opened by the session.
    ///   - pairingRecord: Existing Lockdown pairing record for the target
    ///     device.
    ///   - label: Client label sent in Lockdown requests for diagnostics.
    /// - Returns: An authenticated session whose higher-level operations are
    ///   independent of the supplied transport.
    /// - Throws: Pairing, Lockdown, secure-session, transport, or protocol
    ///   errors encountered while opening the session.
    public func connect(
        over transport: any DeviceTransport,
        using pairingRecord: PairingRecord,
        label: String = "rorkdevice"
    ) async throws -> DeviceSession {
        var connection = try await transport.connect(to: 62078)
        do {
            let lockdown = LockdownClient(connection: connection, label: label)
            let session = try await lockdown.startSession(using: pairingRecord)
            if session.requiresSecureConnection {
                connection = try await secureSessionUpgrader.upgrade(
                    connection,
                    pairingRecord: pairingRecord
                )
            }
        } catch {
            connection.close()
            throw error
        }

        return DeviceSession(
            transport: transport,
            lockdown: LockdownClient(connection: connection, label: label),
            pairingRecord: pairingRecord,
            label: label,
            secureSessionUpgrader: secureSessionUpgrader
        )
    }

    /// Reads the device identity fields required to create pairing material.
    ///
    /// This operation does not change trust state and does not require an
    /// existing pairing record. Browser and embedded transports can use the
    /// returned public key and Wi-Fi address to create one candidate host
    /// identity, then submit that same identity through
    /// `pair(using:over:trustTimeout:retryInterval:onProgress:)`.
    ///
    /// - Parameter transport: Route capable of opening Lockdown on port 62078.
    /// - Returns: Stable device identity and public pairing prerequisites.
    /// - Throws: Transport, Lockdown, or protocol errors when required fields
    ///   are missing or malformed.
    public func pairingInformation(
        over transport: any DeviceTransport
    ) async throws -> DevicePairingInformation {
        let connection = try await transport.connect(to: 62078)
        defer {
            connection.close()
        }
        let lockdown = LockdownClient(connection: connection)
        guard
            let deviceIdentifier = try await lockdown.value(
                domain: nil,
                key: "UniqueDeviceID"
            ) as? String,
            !deviceIdentifier.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown UniqueDeviceID was missing or empty."
            )
        }
        guard
            let devicePublicKey = try await lockdown.value(
                domain: nil,
                key: "DevicePublicKey"
            ) as? Data,
            !devicePublicKey.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown DevicePublicKey was missing or empty."
            )
        }
        guard
            let wiFiMACAddress = try await lockdown.value(
                domain: nil,
                key: "WiFiAddress"
            ) as? String,
            !wiFiMACAddress.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown WiFiAddress was missing or empty."
            )
        }
        return DevicePairingInformation(
            deviceIdentifier: deviceIdentifier,
            devicePublicKey: devicePublicKey,
            wiFiMACAddress: wiFiMACAddress
        )
    }

    /// Reads a best-effort unauthenticated snapshot of Lockdown device state.
    ///
    /// A single `GetValue` without a session returns whatever the device exposes
    /// to an untrusted host. Because it never opens a trusted session, it still
    /// works when the session itself is the thing failing — the case worth
    /// diagnosing — and any value the device withholds until trust exists is
    /// reported as `nil` rather than raised as an error.
    ///
    /// - Parameter transport: Route capable of opening Lockdown on port 62078.
    /// - Returns: The identity, clock, and lock state the device exposes.
    public func deviceEnvironment(
        over transport: any DeviceTransport,
        readTimeout: Duration = .seconds(10)
    ) async throws -> DeviceEnvironment {
        let connection = try await transport.connect(to: 62078)
        defer {
            connection.close()
        }
        // A wedged device could accept the connection yet never answer the read.
        // Closing the connection fails a stalled read — which the protocol allows
        // from another task and makes idempotent — so a watchdog bounds the wait
        // instead of hanging the caller. The read completing first cancels it.
        nonisolated(unsafe) let readable = connection
        let watchdog = Task {
            try? await Task.sleep(for: readTimeout)
            readable.close()
        }
        defer {
            watchdog.cancel()
        }
        let values =
            (try? await LockdownClient(connection: connection).deviceValues())
            ?? [:]
        return DeviceEnvironment(
            productVersion: values["ProductVersion"] as? String,
            productType: values["ProductType"] as? String,
            deviceTime: (values["TimeIntervalSince1970"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) },
            isPasswordProtected: values["PasswordProtected"] as? Bool
        )
    }

    /// Establishes Lockdown trust using caller-created pairing material.
    ///
    /// The same candidate record is retried over fresh Lockdown connections
    /// while iOS waits for the Trust dialog. This method returns the completed
    /// record containing the device-issued escrow bag but does not persist it;
    /// the embedding application owns storage appropriate for its platform.
    ///
    /// - Parameters:
    ///   - pairingRecord: Candidate host identity without an escrow bag.
    ///   - transport: Route capable of opening Lockdown on port 62078.
    ///   - trustTimeout: Maximum time to wait for the device-side decision.
    ///   - retryInterval: Delay between checks while confirmation is pending.
    ///   - onProgress: Optional callback for user-facing pairing state.
    /// - Returns: Completed pairing material ready for later sessions.
    /// - Throws: `LockdownPairingError` for user decisions and timeout, or a
    ///   lower-level transport, Lockdown, or pairing-record error.
    public func pair(
        using pairingRecord: PairingRecord,
        over transport: any DeviceTransport,
        trustTimeout: Duration = .seconds(120),
        retryInterval: Duration = .seconds(1),
        onProgress: (@Sendable (DevicePairingProgress) -> Void)? = nil
    ) async throws -> PairingRecord {
        guard trustTimeout >= .zero else {
            throw RorkDeviceError.invalidInput(
                "Pairing trust timeout cannot be negative."
            )
        }
        guard retryInterval > .zero else {
            throw RorkDeviceError.invalidInput(
                "Pairing retry interval must be greater than zero."
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: trustTimeout)
        var reportedWaiting = false
        while true {
            try Task.checkCancellation()
            do {
                let escrowBag = try await requestPairing(
                    pairingRecord,
                    using: transport
                )
                return try pairingRecord.addingEscrowBag(
                    escrowBag
                )
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

    /// Revokes one host identity through a caller-supplied transport.
    ///
    /// This changes device-side trust only. Browser and embedded callers remain
    /// responsible for deleting the corresponding locally stored pairing
    /// record after the request succeeds.
    ///
    /// - Parameters:
    ///   - pairingRecord: Existing host identity trusted by the device.
    ///   - transport: Route capable of opening Lockdown on port 62078.
    public func unpair(
        using pairingRecord: PairingRecord,
        over transport: any DeviceTransport
    ) async throws {
        try await requestUnpairing(
            pairingRecord,
            using: transport
        )
    }

    #if canImport(NIOPosix) && !os(WASI)
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
        return try await connect(
            over: transport,
            using: pairingRecord,
            label: label
        )
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
    #endif

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

/// Public device identity fields used to create Lockdown pairing material.
///
/// These values are safe to obtain before trust exists. The device public key
/// is bound into the generated certificate chain, while the device identifier
/// and Wi-Fi address become fields in the completed pairing record.
public struct DevicePairingInformation: Equatable, Sendable {
    /// Stable device identifier used as the pairing-record storage key.
    public let deviceIdentifier: String

    /// PEM-encoded RSA public key reported by Lockdown.
    public let devicePublicKey: Data

    /// Wi-Fi hardware address retained in the pairing record.
    public let wiFiMACAddress: String
}

/// Best-effort snapshot of unauthenticated Lockdown state, used to explain why
/// a trusted session cannot open.
///
/// Every field is optional: a device may withhold a value until a trusted
/// session exists, so a missing value is itself diagnostic rather than an
/// error, and reading the snapshot never fails on that account.
public struct DeviceEnvironment: Equatable, Sendable {
    /// iOS/iPadOS version, when the device exposes it without host trust.
    public let productVersion: String?

    /// Hardware model identifier such as `iPhone18,1`, when exposed.
    public let productType: String?

    /// Device wall-clock time, when exposed. A large gap from the host clock
    /// points at certificate time-validity failures during the secure session.
    public let deviceTime: Date?

    /// Whether the device reports itself passcode-locked, when exposed.
    public let isPasswordProtected: Bool?

    /// Creates a snapshot from already-read Lockdown values.
    public init(
        productVersion: String?,
        productType: String?,
        deviceTime: Date?,
        isPasswordProtected: Bool?
    ) {
        self.productVersion = productVersion
        self.productType = productType
        self.deviceTime = deviceTime
        self.isPasswordProtected = isPasswordProtected
    }
}

#if canImport(NIOPosix) && !os(WASI)
extension DeviceEvent {
    /// Converts the usbmux protocol event into the transport-neutral public model.
    fileprivate init(_ event: USBMuxDeviceEvent) {
        switch event {
        case .attached(let device):
            self = .attached(
                Device(
                    identifier: device.serialNumber,
                    connection: .usbmux(deviceID: device.deviceID),
                    properties: device.properties
                ))
        case .detached(let deviceID, let serialNumber):
            self = .detached(identifier: serialNumber, connection: .usbmux(deviceID: deviceID))
        }
    }
}
#endif
