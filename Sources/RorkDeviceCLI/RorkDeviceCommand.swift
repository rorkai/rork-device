import ArgumentParser
import Foundation
import RorkDevice

/// Root command for the `rorkdevice` CLI.
@main
struct RorkDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rorkdevice",
        abstract: "Modern Swift tools for iOS device communication.",
        version: RorkDevice.version,
        subcommands: [
            List.self,
            Watch.self,
            Info.self,
            PairingCommand.self,
            DeveloperModeCommand.self,
            Apps.self,
            Files.self,
            Install.self,
            Uninstall.self,
            Launch.self,
            Terminate.self,
            Profiles.self,
            RemotePairingCommand.self,
            TunnelCommand.self,
        ]
    )
}

/// Shared options for commands that need an authenticated device session.
struct ConnectionOptions: ParsableArguments {
    @Option(help: "Device UDID. Defaults to the first discovered device.")
    var udid: String?

    @Option(help: "Direct Lockdown host. When provided, usbmuxd discovery is skipped.")
    var host: String?

    @Option(help: "Direct Lockdown port.")
    var port: UInt16 = 62078

    @Option(
        help:
            "Existing Lockdown pairing record plist. Defaults to the record stored by usbmuxd."
    )
    var pairingRecord: String?

    @Option(
        help:
            "Device IPv6 address selected by an existing CoreDevice userspace gateway."
    )
    var userspaceDeviceAddress: String?

    @Option(help: "Host running an existing CoreDevice userspace gateway.")
    var userspaceGatewayHost = "127.0.0.1"

    @Option(help: "Port of an existing CoreDevice userspace gateway.")
    var userspaceGatewayPort: UInt16?

    @Option(
        help:
            "Remote Service Discovery port exposed through the userspace gateway."
    )
    var remoteServiceDiscoveryPort: UInt16?

    /// Rejects connection-option combinations that cannot be honored together.
    func validate() throws {
        try validateConnectionOptions()
    }

    /// Requires a route through an existing CoreDevice userspace gateway.
    ///
    /// CoreDevice-only commands cannot run through a Lockdown session because
    /// their services are advertised by Remote Service Discovery.
    func requireUserspaceRoute(for command: String) throws {
        guard usesUserspaceRemoteServiceRoute else {
            throw ValidationError(
                "\(command) requires --userspace-device-address, --userspace-gateway-port, and --remote-service-discovery-port."
            )
        }
    }

    /// Requires a Lockdown route that can create a new CoreDevice tunnel.
    ///
    /// Tunnel startup owns the packet tunnel and gateway lifecycle, so reusing
    /// an already running userspace route would be ambiguous and unsupported.
    func requireLockdownRoute(for command: String) throws {
        guard !usesUserspaceRemoteServiceRoute else {
            throw ValidationError(
                "\(command) requires a Lockdown connection and cannot use userspace gateway options."
            )
        }
    }

    /// Loads and validates an explicitly supplied pairing record.
    func pairingRecordValue() throws -> PairingRecord {
        guard let pairingRecord else {
            throw ValidationError(
                "--pairing-record is required for direct Lockdown connections."
            )
        }
        return try PairingRecord.load(from: URL(fileURLWithPath: pairingRecord))
    }

    /// Opens a direct or usbmux-backed session from parsed CLI options.
    func session(label: String = "rorkdevice") async throws -> DeviceSession {
        try validateConnectionOptions()
        if usesUserspaceRemoteServiceRoute {
            guard let userspaceDeviceAddress,
                  let userspaceGatewayPort,
                  let remoteServiceDiscoveryPort else {
                throw ValidationError(
                    "The userspace route requires --userspace-device-address, --userspace-gateway-port, and --remote-service-discovery-port."
                )
            }
            let transport = try CoreDeviceUserspaceTransport(
                deviceAddress: userspaceDeviceAddress,
                gatewayHost: userspaceGatewayHost,
                gatewayPort: userspaceGatewayPort
            )
            return try await DeviceClient().connect(
                toRemoteServicesUsing: transport,
                discoveryPort: remoteServiceDiscoveryPort,
                label: label
            )
        }
        return try await connectedSession(label: label).session
    }

    /// Opens a session and returns the selected device identifier.
    ///
    /// usbmux-backed commands use the daemon's stored pairing record when no
    /// file was supplied. Direct endpoints cannot query usbmux for the remote
    /// host and therefore continue to require `--pairing-record`.
    func connectedSession(
        label: String = "rorkdevice"
    ) async throws -> (
        session: DeviceSession,
        deviceIdentifier: String
    ) {
        try validateConnectionOptions()
        guard !usesUserspaceRemoteServiceRoute else {
            throw ValidationError(
                "This command requires a Lockdown connection and cannot reuse an existing userspace gateway."
            )
        }
        let client = DeviceClient()
        if let host {
            let pairing = try pairingRecordValue()
            let session = try await client.connect(
                to: host,
                port: port,
                using: pairing,
                label: label
            )
            return (session, pairing.udid)
        }

        let devices = try await client.discoverDevices()
        let selected: Device?
        if let udid {
            selected = devices.first { $0.identifier == udid }
        } else {
            selected = devices.first
        }
        guard let selected else {
            throw ValidationError("No matching device found.")
        }
        let pairing: PairingRecord
        if pairingRecord != nil {
            pairing = try pairingRecordValue()
        } else {
            pairing = try await client.pairingRecord(
                for: selected.identifier
            )
        }
        let session = try await client.connect(
            to: selected,
            using: pairing,
            label: label
        )
        return (session, selected.identifier)
    }

    /// Shared implementation for parse-time and runtime connection validation.
    private func validateConnectionOptions() throws {
        if usesUserspaceRemoteServiceRoute {
            guard let userspaceDeviceAddress,
                  !userspaceDeviceAddress.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  let userspaceGatewayPort,
                  let remoteServiceDiscoveryPort else {
                throw ValidationError(
                    "The userspace route requires --userspace-device-address, --userspace-gateway-port, and --remote-service-discovery-port."
                )
            }
            guard !userspaceGatewayHost.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw ValidationError(
                    "--userspace-gateway-host cannot be empty."
                )
            }
            guard userspaceGatewayPort > 0 else {
                throw ValidationError(
                    "--userspace-gateway-port must be greater than zero."
                )
            }
            guard remoteServiceDiscoveryPort > 0 else {
                throw ValidationError(
                    "--remote-service-discovery-port must be greater than zero."
                )
            }
            guard host == nil,
                  udid == nil,
                  pairingRecord == nil,
                  port == 62078 else {
                throw ValidationError(
                    "Userspace gateway options cannot be combined with Lockdown connection options."
                )
            }
            return
        }

        if host != nil, udid != nil {
            throw ValidationError("--udid cannot be used with --host because direct Lockdown connections skip usbmux discovery.")
        }
        if host == nil, port != 62078 {
            throw ValidationError("--port requires --host.")
        }
    }

    /// Whether any option selects an already running userspace gateway.
    private var usesUserspaceRemoteServiceRoute: Bool {
        userspaceDeviceAddress != nil ||
        userspaceGatewayPort != nil ||
        remoteServiceDiscoveryPort != nil ||
        userspaceGatewayHost != "127.0.0.1"
    }
}

/// Opens AFC or HouseArrest-backed file access from parsed CLI options.
struct FileAccessOptions: ParsableArguments {
    @OptionGroup var connection: ConnectionOptions

    @Option(help: "Application bundle identifier for HouseArrest access.")
    var bundleIdentifier: String?

    @Flag(help: "Request the full app container instead of Documents.")
    var container: Bool = false

    /// Rejects ambiguous file-root selection.
    func validate() throws {
        if container && bundleIdentifier == nil {
            throw ValidationError("--container requires --bundle-identifier.")
        }
    }

    /// Opens the requested AFC view.
    func afcClient() async throws -> AFCClient {
        let session = try await connection.session()
        guard let bundleIdentifier else {
            return try await session.openAFC()
        }
        return try await session.openApplicationContainer(
            bundleIdentifier: bundleIdentifier,
            scope: container ? .container : .documents
        )
    }
}

/// Lists devices currently visible through local usbmux.
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List devices reported by local usbmuxd."
    )

    @Flag(help: "List only devices attached over USB.")
    var usb = false

    @Flag(help: "Include connection metadata in JSON output.")
    var details = false

    @Flag(help: "Print device identifiers as a JSON array.")
    var json = false

    func run() async throws {
        let discoveredDevices = try await DeviceClient().discoverDevices()
        let devices = usb
            ? discoveredDevices.filter(isUSBDevice)
            : discoveredDevices
        if json {
            try FileHandle.standardOutput.write(
                contentsOf: details
                    ? detailedDeviceListJSON(devices)
                    : deviceListJSON(devices)
            )
            try FileHandle.standardOutput.write(
                contentsOf: Data([0x0a])
            )
            return
        }
        if devices.isEmpty {
            print("No devices found.")
            return
        }
        for device in devices {
            if details {
                print(
                    "\(device.identifier)\t\(deviceConnectionType(device) ?? "unknown")"
                )
            } else {
                print(device.identifier)
            }
        }
    }
}

/// Returns whether usbmux reports a physical USB attachment for a device.
///
/// usbmux can advertise the same physical device through both USB and network
/// records. Callers can use this distinction when an operation requires direct
/// cable access to local pairing material or a user-facing Trust prompt.
func isUSBDevice(_ device: Device) -> Bool {
    device.properties["ConnectionType"]?.caseInsensitiveCompare("USB")
        == .orderedSame
}

/// Encodes device identifiers for machine-readable discovery consumers.
///
/// The JSON form intentionally omits transport details so callers receive the
/// same stable array shape regardless of the usbmux protocol revision.
func deviceListJSON(_ devices: [Device]) throws -> Data {
    let encoder = JSONEncoder()
    return try encoder.encode(devices.map(\.identifier))
}

/// Encodes device routes and usbmux properties for discovery consumers.
///
/// The detailed shape preserves multiple transport observations and lets
/// callers distinguish USB from network visibility without invoking Lockdown.
func detailedDeviceListJSON(_ devices: [Device]) throws -> Data {
    let entries = devices.map { device in
        DetailedDeviceListEntry(
            udid: device.identifier,
            connectionType: deviceConnectionType(device),
            properties: device.properties
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(entries)
}

/// Machine-readable device entry emitted by `list --details --json`.
private struct DetailedDeviceListEntry: Encodable {
    /// Stable device identifier reported by usbmux.
    let udid: String

    /// Normalized transport name when usbmux reports one.
    let connectionType: String?

    /// Scalar usbmux discovery properties.
    let properties: [String: String]
}

/// Normalizes usbmux transport metadata for JSON and event output.
private func deviceConnectionType(_ device: Device) -> String? {
    guard let value = device.properties["ConnectionType"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value.lowercased()
}

/// Streams device attach and detach events from local usbmux.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch usbmux device attach and detach events."
    )

    @Flag(help: "Print one JSON object per event.")
    var json = false

    func run() async throws {
        for try await event in DeviceClient().deviceEvents() {
            if json {
                var data = try deviceEventJSON(event)
                data.append(0x0a)
                try FileHandle.standardOutput.write(contentsOf: data)
                continue
            }
            switch event {
            case .attached(let device):
                print("attached\t\(device.identifier)")
            case .detached(let identifier, let connection):
                let value = identifier ?? connection.map(String.init(describing:)) ?? "-"
                print("detached\t\(value)")
            }
        }
    }
}

/// Encodes one device event for newline-delimited stream consumers.
func deviceEventJSON(_ event: DeviceEvent) throws -> Data {
    let value: DeviceEventOutput
    switch event {
    case let .attached(device):
        value = DeviceEventOutput(
            event: "attached",
            udid: device.identifier,
            connectionType: deviceConnectionType(device),
            properties: device.properties
        )
    case let .detached(identifier, _):
        value = DeviceEventOutput(
            event: "detached",
            udid: identifier,
            connectionType: nil,
            properties: nil
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

/// Stable JSON shape emitted by `watch --json`.
private struct DeviceEventOutput: Encodable {
    /// Lowercase event kind.
    let event: String

    /// Device identifier when usbmux includes it.
    let udid: String?

    /// Normalized transport for attach events.
    let connectionType: String?

    /// Scalar usbmux properties for attach events.
    let properties: [String: String]?
}

/// Groups lifecycle operations for the Lockdown pairing stored by local usbmux.
///
/// These commands establish, validate, export, and remove host trust
/// explicitly.
struct PairingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pairing",
        abstract: "Manage the host pairing used by Lockdown.",
        subcommands: [
            PairingEstablish.self,
            PairingExport.self,
            PairingRemove.self,
            PairingValidate.self,
        ]
    )
}

/// Creates or refreshes the selected device's stored host pairing.
///
/// The command waits for the user to respond to the Trust dialog and reuses one
/// generated identity for every check. Successful pairing is persisted through
/// usbmux before the command exits.
struct PairingEstablish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "establish",
        abstract: "Establish and save host trust for a USB device."
    )

    @Option(help: "Device UDID. Defaults to the first USB device.")
    var udid: String?

    @Option(help: "Seconds to wait for the device-side Trust decision.")
    var trustTimeout = 120.0

    /// Rejects timeouts that cannot represent a bounded wait.
    func validate() throws {
        guard trustTimeout.isFinite, trustTimeout >= 0 else {
            throw ValidationError(
                "--trust-timeout must be a nonnegative finite number."
            )
        }
    }

    /// Runs the complete pairing transaction and reports user-action phases.
    func run() async throws {
        let client = DeviceClient()
        let device = try await selectedUSBDevice(
            from: client,
            udid: udid
        )
        _ = try await client.pair(
            with: device,
            trustTimeout: .milliseconds(
                Int64(trustTimeout * 1_000)
            )
        ) { progress in
            writePairingProgress(progress)
        }
        print("Pairing is established for \(device.identifier).")
    }
}

/// Exports the complete pairing record stored by usbmux.
struct PairingExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export the stored host pairing record."
    )

    @Option(help: "Device UDID. Defaults to the first USB device.")
    var udid: String?

    @Option(
        name: .customLong("output"),
        help: "Destination property-list path. Defaults to standard output."
    )
    var outputPath: String?

    /// Writes a complete XML property list without narrowing its fields.
    func run() async throws {
        let client = DeviceClient()
        let device = try await selectedUSBDevice(
            from: client,
            udid: udid
        )
        let record = try await client.pairingRecord(
            for: device.identifier
        )
        let data = try record.propertyListData()
        if let outputPath {
            let destination = URL(fileURLWithPath: outputPath)
                .standardizedFileURL
            try data.write(to: destination, options: .atomic)
            print(destination.path)
        } else {
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

/// Revokes the selected device's trust in this host.
///
/// Lockdown removes the trusted identity from the device before usbmux deletes
/// the host's stored pairing record. A failed device-side request therefore
/// leaves the local credentials available for diagnosis or another attempt.
struct PairingRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove host trust and its stored pairing record."
    )

    @Option(help: "Device UDID. Defaults to the first USB device.")
    var udid: String?

    /// Revokes device trust and then removes the persisted host credentials.
    ///
    /// Output is written only after both stages succeed, so scripts never
    /// mistake a device-only revocation or host-storage failure for completion.
    func run() async throws {
        let client = DeviceClient()
        let device = try await selectedUSBDevice(
            from: client,
            udid: udid
        )
        try await client.unpair(from: device)
        print("Pairing was removed for \(device.identifier).")
    }
}

/// Resolves one cable-attached device for pairing-specific commands.
private func selectedUSBDevice(
    from client: DeviceClient,
    udid: String?
) async throws -> Device {
    let devices = try await client.discoverDevices()
        .filter(isUSBDevice)
    let selected = udid.map { expected in
        devices.first { $0.identifier == expected }
    } ?? devices.first
    guard let selected else {
        throw ValidationError("No matching USB device found.")
    }
    return selected
}

/// Writes pairing phases to stderr so stdout remains command output.
private func writePairingProgress(_ progress: DevicePairingProgress) {
    let message: String
    switch progress {
    case .waitingForUserConfirmation:
        message = "Waiting for the iPhone to trust this Mac."
    case .savingPairingRecord:
        message = "Saving the accepted pairing record."
    }
    guard let data = "rorkdevice: \(message)\n".data(
        using: .utf8
    ) else {
        return
    }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// Verifies that the selected device accepts the stored host pairing.
///
/// A successful command proves that the pairing record can establish an
/// authenticated Lockdown session and that the session identifies the device
/// selected by the caller.
struct PairingValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate the stored host pairing for a device."
    )

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let connected = try await connection.connectedSession()
        let info = try await connected.session.fetchDeviceInfo()
        try validatePairingIdentity(
            info,
            expectedDeviceIdentifier: connected.deviceIdentifier
        )
        print("Pairing is valid for \(connected.deviceIdentifier).")
    }
}

/// Checks that Lockdown authenticated the physical device selected by usbmux.
///
/// Establishing the session proves the host credentials were accepted. The
/// identifier check additionally prevents a stale or mismatched pairing record
/// from being treated as valid for a different device.
func validatePairingIdentity(
    _ info: DeviceInfo,
    expectedDeviceIdentifier: String
) throws {
    guard let actualDeviceIdentifier = info.uniqueDeviceID else {
        throw RorkDeviceError.protocolViolation(
            "Lockdown pairing validation did not return UniqueDeviceID."
        )
    }
    guard actualDeviceIdentifier == expectedDeviceIdentifier else {
        throw RorkDeviceError.invalidPairingRecord(
            "Lockdown returned device \(actualDeviceIdentifier), expected \(expectedDeviceIdentifier)."
        )
    }
}

/// Groups user-controlled Developer Mode setup operations.
///
/// The command group exposes preparation steps only. Enabling Developer Mode,
/// restarting iOS, and confirming the post-restart prompt remain user actions.
struct DeveloperModeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "developer-mode",
        abstract: "Prepare Developer Mode setup on an iOS device.",
        subcommands: [
            DeveloperModeStatus.self,
            DeveloperModeReveal.self,
        ]
    )
}

/// Reads the current Developer Mode state without changing device settings.
struct DeveloperModeStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read whether Developer Mode is enabled."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(help: "Print the Boolean result as JSON.")
    var json = false

    func run() async throws {
        let enabled = try await connection.session()
            .isDeveloperModeEnabled()
        if json {
            print(enabled ? "true" : "false")
        } else {
            print(enabled ? "enabled" : "disabled")
        }
    }
}

/// Reveals the Developer Mode setting without enabling it automatically.
///
/// The selected device must already trust the host because the command opens
/// the authenticated AMFI Lockdown service.
struct DeveloperModeReveal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Reveal Developer Mode in the device Settings app."
    )

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let session = try await connection.session()
        try await session.revealDeveloperMode()
        print("Developer Mode is available in Settings.")
    }
}

/// Parent command for remote-pairing identity operations.
struct RemotePairingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-pairing",
        abstract: "Manage the identity used by CoreDevice remote pairing.",
        subcommands: [
            RemotePairingTrustCommand.self,
        ]
    )
}

/// Ensures that an iPhone trusts a remote-pairing identity.
struct RemotePairingTrustCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Verify an identity or complete the iPhone trust flow."
    )

    @Option(
        name: .customLong("identity"),
        help: "Remote-pairing identity property list."
    )
    var identityPath: String

    @Option(help: "Device IPv6 address inside the userspace tunnel.")
    var deviceAddress: String

    @Option(help: "Remote Service Discovery port reported by the active tunnel.")
    var discoveryPort: UInt16

    @Option(help: "Host running the CoreDevice userspace gateway.")
    var gatewayHost = "127.0.0.1"

    @Option(help: "Local CoreDevice userspace gateway port.")
    var gatewayPort: UInt16

    /// Rejects blank addresses and zero-valued ports before connecting.
    func validate() throws {
        guard !deviceAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--device-address cannot be empty.")
        }
        guard !gatewayHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--gateway-host cannot be empty.")
        }
        guard discoveryPort > 0 else {
            throw ValidationError(
                "--discovery-port must be greater than zero."
            )
        }
        guard gatewayPort > 0 else {
            throw ValidationError("--gateway-port must be greater than zero.")
        }
    }

    /// Verifies the identity and waits for manual trust when required.
    func run() async throws {
        let identity = try RemotePairingIdentity(
            contentsOf: URL(fileURLWithPath: identityPath)
        )
        let transport = try CoreDeviceUserspaceTransport(
            deviceAddress: deviceAddress,
            gatewayHost: gatewayHost,
            gatewayPort: gatewayPort
        )
        try await RemotePairingTrust.establishIfNeeded(
            for: identity,
            using: transport,
            discoveryPort: discoveryPort
        )
        print("Remote-pairing identity is trusted.")
    }
}

/// Parent command for CoreDevice packet-tunnel operations.
struct TunnelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tunnel",
        abstract: "Open and expose CoreDevice packet tunnels.",
        subcommands: [
            TunnelStartCommand.self,
        ]
    )
}

/// Starts a complete userspace tunnel and its local service gateway.
struct TunnelStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract:
            "Start a CoreDevice userspace network and loopback TCP gateway."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(
        name: .customLong("identity"),
        help:
            "Stable remote-pairing identity plist. A new identity is created when the file does not exist."
    )
    var identityPath: String

    @Option(help: "Local address for the userspace service gateway.")
    var gatewayHost = "127.0.0.1"

    @Option(
        help:
            "Local gateway port. Zero asks the operating system for an available port."
    )
    var gatewayPort: UInt16 = 0

    @Option(
        name: .customLong("mtu"),
        help: "Maximum IPv6 packet size requested from CoreDevice."
    )
    var maximumTransmissionUnit: UInt16 = 1_280

    /// Rejects tunnel settings that cannot form a valid IPv6 link.
    func validate() throws {
        try connection.validate()
        try connection.requireLockdownRoute(for: "tunnel start")
        guard !gatewayHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--gateway-host cannot be empty.")
        }
        guard maximumTransmissionUnit >= 1_280 else {
            throw ValidationError("--mtu must be at least 1280.")
        }
    }

    /// Opens the packet tunnel, establishes trust, and serves until terminated.
    func run() async throws {
        let identityURL = URL(fileURLWithPath: identityPath)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: identityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let identity = try RemotePairingIdentity.loadOrCreate(
            at: identityURL
        )
        writeTunnelProgress(
            "Loaded remote-pairing identity \(identity.identifier)."
        )
        let connected = try await connection.connectedSession(
            label: "rorkdevice-tunnel"
        )
        writeTunnelProgress(
            "Opened Lockdown session for \(connected.deviceIdentifier)."
        )
        let tunnel = try await connected.session.openCoreDeviceTunnel(
            requestedMaximumTransmissionUnit:
                maximumTransmissionUnit
        )
        writeTunnelProgress(
            "Negotiated CoreDevice tunnel to \(tunnel.configuration.deviceAddress):\(tunnel.configuration.serviceDiscoveryPort)."
        )

        let network: CoreDeviceUserspaceNetwork
        do {
            network = try CoreDeviceUserspaceNetwork(tunnel: tunnel)
        } catch {
            tunnel.close()
            throw error
        }

        let gateway: CoreDeviceUserspaceGateway
        do {
            gateway = try await CoreDeviceUserspaceGateway.start(
                network: network,
                host: gatewayHost,
                port: gatewayPort
            )
        } catch {
            network.close()
            throw error
        }
        defer {
            gateway.close()
        }
        writeTunnelProgress(
            "Listening on \(gateway.host):\(gateway.port)."
        )

        try await RemotePairingTrust.establishIfNeeded(
            for: identity,
            using: network,
            discoveryPort:
                network.configuration.serviceDiscoveryPort,
            progress: writeRemotePairingProgress
        )
        try writeTunnelReadyEvent(
            deviceIdentifier: connected.deviceIdentifier,
            identityPath: identityURL.path,
            network: network,
            gateway: gateway
        )

        try await withTaskCancellationHandler {
            try await gateway.waitUntilClosed()
        } onCancel: {
            gateway.close()
        }
    }
}

/// Machine-readable event emitted once a tunnel can accept local clients.
private struct TunnelReadyEvent: Encodable {
    let event = "ready"
    let address: String
    let rsdPort: UInt16
    let udid: String
    let userspaceTun = true
    let userspaceTunHost: String
    let userspaceTunPort: UInt16
    let identityPath: String
}

/// Writes one newline-delimited ready event without stdout buffering.
private func writeTunnelReadyEvent(
    deviceIdentifier: String,
    identityPath: String,
    network: CoreDeviceUserspaceNetwork,
    gateway: CoreDeviceUserspaceGateway
) throws {
    let event = TunnelReadyEvent(
        address: network.configuration.deviceAddress,
        rsdPort: network.configuration.serviceDiscoveryPort,
        udid: deviceIdentifier,
        userspaceTunHost: gateway.host,
        userspaceTunPort: gateway.port,
        identityPath: identityPath
    )
    var data = try JSONEncoder().encode(event)
    data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}

/// Writes human-readable tunnel progress separately from machine-readable stdout.
private func writeTunnelProgress(_ message: String) {
    guard let data = "rorkdevice: \(message)\n".data(using: .utf8) else {
        return
    }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// Converts typed trust phases into concise operator-facing CLI diagnostics.
private func writeRemotePairingProgress(
    _ progress: RemotePairingTrust.Progress
) {
    switch progress {
    case .openingServiceDiscovery:
        writeTunnelProgress("Opening Remote Service Discovery.")
    case .openingPairingService:
        writeTunnelProgress("Opening the remote-pairing service.")
    case .verifyingIdentity:
        writeTunnelProgress("Verifying the remote-pairing identity.")
    case .enrollingIdentity:
        writeTunnelProgress(
            "Waiting for the iPhone to approve the remote-pairing identity."
        )
    case .established:
        writeTunnelProgress("Remote-pairing trust is established.")
    }
}

/// Prints common Lockdown information for the selected device.
struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print basic Lockdown device information."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(help: "Print the complete scalar Lockdown value dictionary as JSON.")
    var json = false

    func run() async throws {
        let session = try await connection.session()
        let info = try await session.fetchDeviceInfo()
        if json {
            try FileHandle.standardOutput.write(
                contentsOf: lockdownInfoJSON(info)
            )
            try FileHandle.standardOutput.write(
                contentsOf: Data([0x0a])
            )
            return
        }
        print("UDID: \(info.uniqueDeviceID ?? "-")")
        print("Name: \(info.deviceName ?? "-")")
        print("Product: \(info.productType ?? "-")")
        print("Version: \(info.productVersion ?? "-")")
        print("Build: \(info.buildVersion ?? "-")")
    }
}

/// Encodes scalar Lockdown values for machine-readable CLI consumers.
///
/// The output remains a flat dictionary with the original Lockdown key names
/// so clients can consume newer scalar keys without requiring a CLI release.
func lockdownInfoJSON(_ info: DeviceInfo) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(info.rawValues)
}

/// Parent command for AFC and HouseArrest file operations.
struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files",
        abstract: "Manage files through AFC or HouseArrest.",
        subcommands: [
            FilesList.self,
            FilesInfo.self,
            FilesPull.self,
            FilesPush.self,
            FilesMakeDirectory.self,
            FilesRemove.self,
            FilesMove.self,
        ]
    )
}

/// Lists entries in a remote directory.
struct FilesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a remote directory."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Remote directory path.")
    var path: String = "/"

    func run() async throws {
        let afc = try await access.afcClient()
        for name in try await afc.directoryContents(at: path) {
            print(name)
        }
    }
}

/// Prints metadata for a remote path.
struct FilesInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print remote path metadata."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Remote path.")
    var path: String

    func run() async throws {
        let afc = try await access.afcClient()
        let info = try await afc.fileInfo(at: path)
        for key in info.values.keys.sorted() {
            print("\(key): \(info.values[key] ?? "")")
        }
    }
}

/// Downloads a remote file.
struct FilesPull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Download a remote file."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Remote file path.")
    var remotePath: String

    @Argument(help: "Local output path.")
    var localPath: String

    func run() async throws {
        let afc = try await access.afcClient()
        try await afc.downloadFile(from: remotePath, to: URL(fileURLWithPath: localPath))
    }
}

/// Uploads a local file.
struct FilesPush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Upload a local file."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Local file path.")
    var localPath: String

    @Argument(help: "Remote output path.")
    var remotePath: String

    func run() async throws {
        let afc = try await access.afcClient()
        try await afc.uploadFile(at: URL(fileURLWithPath: localPath), to: remotePath)
    }
}

/// Creates a remote directory.
struct FilesMakeDirectory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir",
        abstract: "Create a remote directory."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Remote directory path.")
    var path: String

    func run() async throws {
        let afc = try await access.afcClient()
        try await afc.makeDirectory(path)
    }
}

/// Removes a remote file or directory.
struct FilesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a remote file or directory."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Remote path.")
    var path: String

    func run() async throws {
        let afc = try await access.afcClient()
        try await afc.removePath(path)
    }
}

/// Moves or renames a remote path.
struct FilesMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move or rename a remote path."
    )

    @OptionGroup var access: FileAccessOptions

    @Argument(help: "Existing remote path.")
    var sourcePath: String

    @Argument(help: "New remote path.")
    var destinationPath: String

    func run() async throws {
        let afc = try await access.afcClient()
        try await afc.movePath(from: sourcePath, to: destinationPath)
    }
}

/// Parent command for installed-application operations.
struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Manage installed apps.",
        subcommands: [AppsList.self]
    )
}

/// Lists installed applications through the selected session backend.
struct AppsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed apps."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(help: "Application type: user, system, internal, or all.")
    var type: ApplicationType = .user

    func run() async throws {
        let session = try await connection.session()
        let apps = try await session.installedApplications(matching: type)
        for app in apps {
            let identifier = app.bundleIdentifier ?? "-"
            let name = app.displayName ?? "-"
            print("\(identifier)\t\(name)")
        }
    }
}

/// Installs an IPA by staging it through AFC and invoking InstallationProxy.
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an IPA."
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "IPA path.")
    var ipaPath: String

    @Option(help: "Bundle identifier for the IPA.")
    var bundleIdentifier: String

    func run() async throws {
        let session = try await connection.session()
        try await session.installApplication(
            at: URL(fileURLWithPath: ipaPath),
            bundleIdentifier: bundleIdentifier
        ) { event in
            if let percent = event.percentComplete {
                print("\(event.status) \(percent)%")
            } else {
                print(event.status)
            }
        }
    }
}

/// Uninstalls an app through InstallationProxy.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall an app by bundle identifier."
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Bundle identifier.")
    var bundleIdentifier: String

    func run() async throws {
        let session = try await connection.session()
        try await session.uninstallApplication(bundleIdentifier: bundleIdentifier) { event in
            print(event.status)
        }
    }
}

/// Launches an installed application through CoreDevice's app service.
struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(
        name: .customLong("kill-existing"),
        help: "Terminate an existing app process before launching."
    )
    var killExisting = false

    @Option(
        name: .customLong("arg"),
        parsing: .unconditionalSingleValue,
        help: "Argument passed to the app. May be repeated."
    )
    var arguments: [String] = []

    @Option(
        name: .customLong("env"),
        parsing: .unconditionalSingleValue,
        help: "Environment entry in KEY=VALUE form. May be repeated."
    )
    var environment: [String] = []

    @Argument(help: "Bundle identifier.")
    var bundleIdentifier: String

    /// Rejects malformed environment assignments before opening the device.
    func validate() throws {
        try connection.requireUserspaceRoute(for: "launch")
        _ = try parsedEnvironment()
    }

    /// Opens the selected RSD session and launches the requested application.
    func run() async throws {
        let session = try await connection.session()
        let processIdentifier = try await session.launchApplication(
            bundleIdentifier: bundleIdentifier,
            options: ApplicationLaunchOptions(
                arguments: arguments,
                environment: try parsedEnvironment(),
                terminateExistingProcess: killExisting
            )
        )
        print(processIdentifier)
    }

    /// Converts repeated `KEY=VALUE` arguments into CoreDevice environment data.
    private func parsedEnvironment() throws -> [String: String] {
        try environment.reduce(into: [:]) { result, assignment in
            let parts = assignment.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ValidationError(
                    "--env values must use non-empty KEY=VALUE syntax."
                )
            }
            result[String(parts[0])] = String(parts[1])
        }
    }
}

/// Terminates an installed application's running CoreDevice processes.
struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate",
        abstract: "Terminate a running app."
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Bundle identifier.")
    var bundleIdentifier: String

    /// Requires the Remote Service Discovery route used by process control.
    func validate() throws {
        try connection.requireUserspaceRoute(for: "terminate")
    }

    /// Opens the selected RSD session and terminates matching app processes.
    func run() async throws {
        let session = try await connection.session()
        let terminated = try await session.terminateApplication(
            bundleIdentifier: bundleIdentifier
        )
        print(terminated ? "Terminated." : "Application is not running.")
    }
}

/// Parent command for provisioning-profile operations.
struct Profiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Manage provisioning profiles.",
        subcommands: [
            ProfilesInstall.self,
            ProfilesCopy.self,
            ProfilesRemove.self,
        ]
    )
}

/// Installs a provisioning profile through MISAgent.
struct ProfilesInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a provisioning profile."
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Provisioning profile path.")
    var profilePath: String

    func run() async throws {
        let session = try await connection.session()
        try await session.installProvisioningProfile(contentsOf: URL(fileURLWithPath: profilePath))
    }
}

/// Copies installed provisioning profiles from the device.
struct ProfilesCopy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy installed provisioning profiles."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(help: "Directory that will receive copied .mobileprovision files.")
    var outputDirectory: String

    @Flag(help: "Use the legacy MISAgent Copy command for iOS 9.2.1 and older.")
    var legacy: Bool = false

    func run() async throws {
        let session = try await connection.session()
        let mode: ProvisioningProfileCopyMode = legacy ? .legacy : .all
        let profiles = try await session.copyProvisioningProfiles(mode: mode)
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, profile) in profiles.enumerated() {
            let url = directory.appendingPathComponent("profile-\(index + 1).mobileprovision")
            try profile.write(to: url, options: .atomic)
            print(url.path)
        }
    }
}

/// Removes a provisioning profile from the device.
struct ProfilesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a provisioning profile by UUID."
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Provisioning profile UUID.")
    var identifier: String

    func run() async throws {
        let session = try await connection.session()
        try await session.removeProvisioningProfile(identifier: identifier)
    }
}

extension ApplicationType: ExpressibleByArgument {
    /// Creates an application-type filter from the CLI argument value.
    public init?(argument: String) {
        let normalized = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "user":
            self = .user
        case "system":
            self = .system
        case "internal", "internal-applications":
            self = .internalApplications
        case "any", "all":
            self = .all
        default:
            self.init(rawValue: argument)
        }
    }
}
