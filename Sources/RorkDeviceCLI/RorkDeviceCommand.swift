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
            ImageCommand.self,
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
    /// The serving agent's shared per-cycle session.
    ///
    /// The tunnel agent binds this task local while it runs a command
    /// in-process for the `run` operation, so the command reuses the live
    /// session instead of dialing its own connection. Commands run from the
    /// shell never see a binding and dial exactly as before.
    @TaskLocal static var injectedSession: DeviceSession?

    /// Where a command line came from, which decides how the connection
    /// options validate.
    enum ParsingContext: Sendable {
        /// The command line came from a shell or another direct caller,
        /// and the command dials the connection its options describe.
        case shell

        /// The command line came from a serving agent's `run` request,
        /// and the command reuses the agent's shared tunnel session.
        ///
        /// That session never reads the connection options, so a device
        /// or route selection would be silently ignored rather than
        /// honored. A request that named another attached device would
        /// run against the served device and exit cleanly, so a read
        /// returns the wrong device's data and a destructive command
        /// acts on the wrong device. Validation therefore rejects those
        /// options loudly. The same context satisfies
        /// `requireUserspaceRoute(for:)`, because the shared session is
        /// itself the userspace route that requirement guarantees.
        case servedTunnel
    }

    /// The context the current task parses command lines for.
    @TaskLocal static var parsingContext = ParsingContext.shell

    /// Default Lockdown port, shared by the declaration and the
    /// route-selection check.
    static let defaultPort: UInt16 = 62078

    /// Default gateway host, shared by the declaration and the
    /// route-selection check.
    static let defaultUserspaceGatewayHost = "127.0.0.1"

    @Option(help: "Device UDID. Defaults to the first discovered device.")
    var udid: String?

    @Option(help: "Direct Lockdown host. When provided, usbmuxd discovery is skipped.")
    var host: String?

    @Option(help: "Direct Lockdown port.")
    var port: UInt16 = ConnectionOptions.defaultPort

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
    var userspaceGatewayHost = ConnectionOptions.defaultUserspaceGatewayHost

    @Option(help: "Port of an existing CoreDevice userspace gateway.")
    var userspaceGatewayPort: UInt16?

    @Option(
        help:
            "Remote Service Discovery port exposed through the userspace gateway."
    )
    var remoteServiceDiscoveryPort: UInt16?

    /// Rejects connection-option combinations that cannot be honored together.
    func validate() throws {
        try validateNoRouteSelectionWhileServing()
        try validateConnectionOptions()
    }

    /// A declared option that selects a device or a route.
    ///
    /// The raw value is the option's command-line spelling, so a rejection
    /// can name the exact tokens to drop.
    enum RouteSelectingOption: String, CaseIterable {
        case udid = "--udid"
        case host = "--host"
        case port = "--port"
        case pairingRecord = "--pairing-record"
        case userspaceDeviceAddress = "--userspace-device-address"
        case userspaceGatewayHost = "--userspace-gateway-host"
        case userspaceGatewayPort = "--userspace-gateway-port"
        case remoteServiceDiscoveryPort = "--remote-service-discovery-port"

        /// Whether the parsed options deviate from this option's default.
        func isSelected(in options: ConnectionOptions) -> Bool {
            switch self {
            case .udid:
                options.udid != nil
            case .host:
                options.host != nil
            case .port:
                options.port != ConnectionOptions.defaultPort
            case .pairingRecord:
                options.pairingRecord != nil
            case .userspaceDeviceAddress:
                options.userspaceDeviceAddress != nil
            case .userspaceGatewayHost:
                options.userspaceGatewayHost != ConnectionOptions.defaultUserspaceGatewayHost
            case .userspaceGatewayPort:
                options.userspaceGatewayPort != nil
            case .remoteServiceDiscoveryPort:
                options.remoteServiceDiscoveryPort != nil
            }
        }
    }

    /// Rejects device and route selection while the serving agent parses.
    ///
    /// The check runs before the combination rules, which would otherwise
    /// answer an incomplete userspace triple with advice to add more of the
    /// very options a served command cannot use.
    private func validateNoRouteSelectionWhileServing() throws {
        guard Self.parsingContext == .servedTunnel else {
            return
        }
        let selected = RouteSelectingOption.allCases.filter { option in
            option.isSelected(in: self)
        }
        guard selected.isEmpty else {
            throw ValidationError(
                "run pins the connection to the served tunnel, so \(selected.map(\.rawValue).joined(separator: ", ")) is not accepted."
            )
        }
    }

    /// Requires a route through an existing CoreDevice userspace gateway.
    ///
    /// CoreDevice-only commands cannot run through a Lockdown session because
    /// their services are advertised by Remote Service Discovery.
    func requireUserspaceRoute(for command: String) throws {
        // The serving agent's shared session is an RSD-backed userspace
        // route, so a served command already has what this guarantees.
        if Self.parsingContext == .servedTunnel {
            return
        }
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

    /// Opens a direct or usbmux-backed session from parsed CLI options,
    /// or returns the serving agent's session when one is bound.
    func session(label: String = "rorkdevice") async throws -> DeviceSession {
        if let injected = Self.injectedSession {
            return injected
        }
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
        label: String = "rorkdevice",
        client: DeviceClient = DeviceClient()
    ) async throws -> (
        session: DeviceSession,
        deviceIdentifier: String
    ) {
        let target = try await lockdownTarget(using: client)
        let session = try await client.connect(
            to: target.device,
            using: target.pairingRecord,
            label: label
        )
        return (session, target.device.identifier)
    }

    /// Resolves one stable Lockdown route and its pairing record without opening TLS.
    func lockdownTarget(
        using client: DeviceClient = DeviceClient()
    ) async throws -> (
        device: Device,
        pairingRecord: PairingRecord
    ) {
        try validateConnectionOptions()
        guard !usesUserspaceRemoteServiceRoute else {
            throw ValidationError(
                "This command requires a Lockdown connection and cannot reuse an existing userspace gateway."
            )
        }
        if let host {
            let pairing = try pairingRecordValue()
            return (
                Device(
                    identifier: pairing.udid,
                    connection: .direct(host: host, port: port)
                ),
                pairing
            )
        }

        let selected: Device?
        if let udid {
            selected = try await client.discoverDevice(
                identifier: udid
            )
        } else {
            selected = try await client.discoverDevices().first
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
        return (selected, pairing)
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
            try CommandOutput.write(
                contentsOf: details
                    ? detailedDeviceListJSON(devices)
                    : deviceListJSON(devices)
            )
            try CommandOutput.write(
                contentsOf: Data([0x0a])
            )
            return
        }
        if devices.isEmpty {
            CommandOutput.print("No devices found.")
            return
        }
        for device in devices {
            if details {
                CommandOutput.print(
                    "\(device.identifier)\t\(deviceConnectionType(device) ?? "unknown")"
                )
            } else {
                CommandOutput.print(device.identifier)
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
                try CommandOutput.write(contentsOf: data)
                continue
            }
            switch event {
            case .attached(let device):
                CommandOutput.print("attached\t\(device.identifier)")
            case .detached(let identifier, let connection):
                let value = identifier ?? connection.map(String.init(describing:)) ?? "-"
                CommandOutput.print("detached\t\(value)")
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
/// These commands establish, validate, export, and remove host trust, and
/// configure the device's wireless Lockdown route.
struct PairingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pairing",
        abstract: "Manage the host pairing used by Lockdown.",
        subcommands: [
            PairingEstablish.self,
            PairingExport.self,
            PairingRemove.self,
            PairingDiagnose.self,
            PairingValidate.self,
            PairingEnableWireless.self,
        ]
    )
}

/// Creates or refreshes the selected device's stored host pairing.
///
/// The command waits for the user to respond to the Trust dialog and reuses one
/// generated identity for every check. Successful pairing is persisted through
/// usbmux and validated on a fresh Lockdown connection before the command exits.
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
            matching: udid
        )
        _ = try await client.pair(
            with: device,
            trustTimeout: .milliseconds(
                Int64(trustTimeout * 1_000)
            )
        ) { progress in
            writePairingProgress(progress)
        }
        _ = try await waitForSavedPairingActivation(
            attemptDelays: savedPairingActivationAttemptDelays,
            sleep: {
                try await Task.sleep(for: $0)
            },
            onRetry: writePairingActivationRetry,
            attempt: {
                try await openValidatedSavedPairingSession(
                    for: device.identifier,
                    label: "rorkdevice pairing establish"
                )
            }
        )
        CommandOutput.print("Pairing is established for \(device.identifier).")
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
            matching: udid
        )
        let record = try await client.pairingRecord(
            for: device.identifier
        )
        let data = try record.propertyListData()
        if let outputPath {
            let destination = URL(fileURLWithPath: outputPath)
                .standardizedFileURL
            try data.write(to: destination, options: .atomic)
            CommandOutput.print(destination.path)
        } else {
            try CommandOutput.write(contentsOf: data)
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
            matching: udid
        )
        try await client.unpair(from: device)
        CommandOutput.print("Pairing was removed for \(device.identifier).")
    }
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
        CommandOutput.print("Pairing is valid for \(connected.deviceIdentifier).")
    }
}

/// Enables the device's wireless Lockdown route for the paired host.
///
/// The command must connect through authenticated Lockdown, normally over USB,
/// before iOS will accept the wireless preference change.
struct PairingEnableWireless: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable-wireless",
        abstract: "Allow the paired host to connect over Wi-Fi."
    )

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let connected = try await connection.connectedSession()
        try await connected.session.enableWirelessConnections()
        CommandOutput.print(
            "Wireless Lockdown is enabled for \(connected.deviceIdentifier)."
        )
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
            CommandOutput.print(enabled ? "true" : "false")
        } else {
            CommandOutput.print(enabled ? "enabled" : "disabled")
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
        CommandOutput.print("Developer Mode is available in Settings.")
    }
}

/// Groups personalized Developer Disk Image operations.
struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage personalized Developer Disk Images.",
        subcommands: [
            ImageMount.self,
            ImageAuto.self,
            ImageUnmount.self,
            ImageList.self,
        ]
    )
}

/// Mounts an already extracted personalized DDI Restore directory.
struct ImageMount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Mount a local personalized DDI Restore directory."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(
        name: .customLong("path"),
        help: "Path to the extracted DDI Restore directory."
    )
    var restorePath: String

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func validate() throws {
        try connection.requireLockdownRoute(for: "image mount")
        guard !restorePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--path cannot be empty.")
        }
    }

    func run() async throws {
        let session = try await connection.session()
        let result = try await session
            .mountPersonalizedDeveloperDiskImage(
                from: URL(
                    fileURLWithPath: restorePath,
                    isDirectory: true
                )
            )
        try writeDeveloperDiskImageMountResult(
            result,
            asJSON: json
        )
    }
}

/// Downloads, authenticates, caches, and mounts a personalized DDI archive.
struct ImageAuto: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Download and mount an authenticated personalized DDI archive."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(help: "HTTPS URL of the personalized DDI ZIP archive.")
    var archiveURL: String

    @Option(help: "Expected SHA-256 of the ZIP archive.")
    var sha256: String

    @Option(help: "Override the extracted DDI cache directory.")
    var cacheDirectory: String?

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func validate() throws {
        try connection.requireLockdownRoute(for: "image auto")
        _ = try source()
        _ = try store()
    }

    func run() async throws {
        let session = try await connection.session()
        let result = try await session
            .mountPersonalizedDeveloperDiskImage(
                from: source(),
                using: store()
            )
        try writeDeveloperDiskImageMountResult(
            result,
            asJSON: json
        )
    }

    /// Validates the user-supplied archive URL and pinned digest together.
    private func source() throws -> DeveloperDiskImageSource {
        guard let url = URL(string: archiveURL) else {
            throw ValidationError(
                "--archive-url must be a valid HTTPS URL."
            )
        }
        return try DeveloperDiskImageSource(
            archiveURL: url,
            expectedSHA256: sha256
        )
    }

    /// Builds either the default store or a validated cache override.
    private func store() throws -> DeveloperDiskImageStore {
        guard let cacheDirectory else {
            return DeveloperDiskImageStore()
        }
        guard !cacheDirectory.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError(
                "--cache-directory cannot be empty."
            )
        }
        return DeveloperDiskImageStore(
            cacheDirectory: URL(
                fileURLWithPath: cacheDirectory,
                isDirectory: true
            )
        )
    }
}

/// Unmounts the personalized Developer Disk Image over the Lockdown route.
struct ImageUnmount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmount",
        abstract: "Unmount the personalized Developer Disk Image."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func validate() throws {
        try connection.requireLockdownRoute(for: "image unmount")
    }

    func run() async throws {
        let session = try await connection.session()
        try await session.unmountPersonalizedDeveloperDiskImage()
        try writeDeveloperDiskImageUnmountResult(asJSON: json)
    }
}

/// Lists the personalized Developer Disk Images the device reports mounted.
struct ImageList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List mounted personalized Developer Disk Images."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func validate() throws {
        try connection.requireLockdownRoute(for: "image list")
    }

    func run() async throws {
        let session = try await connection.session()
        let signatures = try await session
            .mountedPersonalizedDeveloperDiskImages()
        try writeDeveloperDiskImageListResult(signatures, asJSON: json)
    }
}

/// Writes image-unmount output without mixing human text into JSON mode.
private func writeDeveloperDiskImageUnmountResult(asJSON: Bool) throws {
    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CommandOutput.write(
            contentsOf: encoder.encode(
                DeveloperDiskImageUnmountOutput(unmounted: true)
            )
        )
        try CommandOutput.write(contentsOf: Data([0x0a]))
        return
    }
    CommandOutput.print("Unmounted the personalized Developer Disk Image.")
}

/// Writes the mounted-image list without mixing human text into JSON mode.
private func writeDeveloperDiskImageListResult(
    _ signatures: [Data],
    asJSON: Bool
) throws {
    let hexSignatures = signatures.map { signature in
        signature.map { String(format: "%02x", $0) }.joined()
    }
    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CommandOutput.write(
            contentsOf: encoder.encode(
                DeveloperDiskImageListOutput(
                    count: signatures.count,
                    signatures: hexSignatures
                )
            )
        )
        try CommandOutput.write(contentsOf: Data([0x0a]))
        return
    }
    guard !signatures.isEmpty else {
        CommandOutput.print("No personalized Developer Disk Image is mounted.")
        return
    }
    let header = signatures.count == 1
        ? "1 personalized Developer Disk Image is mounted:"
        : "\(signatures.count) personalized Developer Disk Images are mounted:"
    CommandOutput.print(header)
    for hex in hexSignatures {
        CommandOutput.print("- \(hex)")
    }
}

/// Stable JSON shape emitted by `image unmount`.
private struct DeveloperDiskImageUnmountOutput: Encodable {
    let unmounted: Bool
}

/// Stable JSON shape emitted by `image list`.
private struct DeveloperDiskImageListOutput: Encodable {
    let count: Int
    let signatures: [String]
}

/// Encodes the stable machine-readable image-mount result.
func developerDiskImageMountJSON(
    _ result: DeveloperDiskImageMountResult
) throws -> Data {
    let output = DeveloperDiskImageMountOutput(
        status: result.status,
        ticketSource: result.ticketSource,
        requiresTunnelRestart: result.requiresTunnelRestart
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(output)
}

/// Writes image-mount output without mixing human text into JSON mode.
private func writeDeveloperDiskImageMountResult(
    _ result: DeveloperDiskImageMountResult,
    asJSON: Bool
) throws {
    if asJSON {
        try CommandOutput.write(
            contentsOf: developerDiskImageMountJSON(result)
        )
        try CommandOutput.write(contentsOf: Data([0x0a]))
        return
    }
    switch result.status {
    case .alreadyMounted:
        CommandOutput.print("Personalized Developer Disk Image is already mounted.")
    case .mounted:
        CommandOutput.print(
            "Personalized Developer Disk Image mounted. Recreate any existing CoreDevice tunnel before using developer services."
        )
    }
}

/// Stable JSON shape emitted by `image mount` and `image auto`.
private struct DeveloperDiskImageMountOutput: Encodable {
    let status: DeveloperDiskImageMountResult.Status
    let ticketSource: DeveloperDiskImageMountResult.TicketSource?
    let requiresTunnelRestart: Bool
}

/// Parent command for remote-pairing identity operations.
struct RemotePairingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-pairing",
        abstract: "Manage the identity used by CoreDevice remote pairing.",
        subcommands: [
            RemotePairingDiagnoseCommand.self,
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
        CommandOutput.print("Remote-pairing identity is trusted.")
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
    var maximumTransmissionUnit: UInt16 = 4_000

    @Option(
        name: .customLong("stats-interval"),
        help:
            "Seconds between tunnel data-plane statistics lines on stderr. Zero disables statistics."
    )
    var statsInterval: UInt32 = 0

    @Flag(
        help:
            "Keep running when the tunnel drops: re-establish it with backoff and report lifecycle events on stdout."
    )
    var reconnect = false

    @Flag(
        name: .customLong("exit-when-stdin-closes"),
        help:
            "Exit when standard input reaches end-of-file, so a supervising process that dies cannot orphan this tunnel."
    )
    var exitWhenStdinCloses = false

    @Flag(
        help:
            "Serve operation requests over standard input and reply on standard output. Implies exiting when standard input closes."
    )
    var serve = false

    /// Rejects tunnel settings that cannot form a valid IPv6 link.
    func validate() throws {
        try connection.validate()
        try connection.requireLockdownRoute(for: "tunnel start")
        guard !serve || reconnect else {
            throw ValidationError("--serve requires --reconnect.")
        }
        guard !gatewayHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--gateway-host cannot be empty.")
        }
        guard maximumTransmissionUnit >= 1_280 else {
            throw ValidationError("--mtu must be at least 1280.")
        }
    }

    /// Delay schedule between reconnect attempts.
    ///
    /// The schedule restarts after every healthy tunnel, so it paces one
    /// outage rather than the process lifetime. The 60-second ceiling keeps a
    /// device that repeatedly fails enrollment from being re-prompted more
    /// than once a minute — the pre-F9 restart loop re-drove enrollment every
    /// ~20 seconds and hammered devices mid-approval.
    private static let reconnectBackoff = Backoff.exponential(
        initial: .seconds(1),
        factor: 2,
        maximum: .seconds(60),
        maxAttempts: Int.max
    )

    /// Opens the packet tunnel, establishes trust, and serves until terminated.
    ///
    /// With `--reconnect`, tunnel loss re-enters establishment with backoff
    /// instead of ending the process, and lifecycle events are reported on
    /// stdout between `ready` lines. With `--exit-when-stdin-closes`, the
    /// process also stops cleanly once standard input reaches end-of-file,
    /// which is how a supervisor's crash reaches an agent that would otherwise
    /// keep reconnecting forever.
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
        if serve {
            // Serving owns standard input. It answers requests while the
            // pipe is open and shuts down when the pipe reaches end-of-file,
            // so the parent-death contract holds without a separate watcher.
            let sessionGate = TunnelAgentSessionGate()
            let handlers = TunnelAgentIPC.builtInHandlers(
                capabilities: TunnelStartCommand.serveCapabilities
            ).merging(
                TunnelAgentOperations.handlers(sessionGate: sessionGate)
            ) { _, operation in
                operation
            }
            try await runSupervised(
                identity: identity,
                identityURL: identityURL,
                sessionGate: sessionGate
            ) {
                await TunnelAgentIPC.serve(
                    requestsFrom: .standardInput,
                    handlers: handlers,
                    send: writeAgentReplyLine
                )
            }
            return
        }

        guard exitWhenStdinCloses else {
            try await serveUntilStopped(
                identity: identity,
                identityURL: identityURL
            )
            return
        }

        try await runSupervised(identity: identity, identityURL: identityURL) {
            await EndOfFileWatch.waitUntilEndOfFile(of: .standardInput)
        }
    }

    /// Operations the serving loop answers, device-backed ones included.
    static let serveCapabilities = ["ping", "capabilities"] + TunnelAgentOperations.names

    /// Runs the tunnel until `untilParentGone` returns, then stops cleanly.
    ///
    /// The wind-down is bounded because establishment steps that do not
    /// observe cancellation promptly must not keep an unsupervised process
    /// alive. A cancelled grace timer means the tunnel wound down first and
    /// the orderly path owns the exit.
    private func runSupervised(
        identity: RemotePairingIdentity,
        identityURL: URL,
        sessionGate: TunnelAgentSessionGate? = nil,
        untilParentGone: @escaping @Sendable () async -> Void
    ) async throws {
        let serving = Task {
            try await serveUntilStopped(
                identity: identity,
                identityURL: identityURL,
                sessionGate: sessionGate
            )
        }
        let supervision = Task {
            await untilParentGone()
            writeTunnelProgress(
                "Standard input closed; stopping because the supervising process is gone."
            )
            serving.cancel()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            writeTunnelProgress("Shutdown grace elapsed; exiting now.")
            Foundation.exit(0)
        }
        defer {
            supervision.cancel()
        }
        do {
            try await serving.value
        } catch where serving.isCancelled {
            // The supervisor is gone and the tunnel wound down in time, so
            // exit cleanly and nothing records this as a crash. Cancellation is
            // matched through `isCancelled` rather than error type because a
            // cancelled establishment step can surface as a transport error
            // from the connection teardown instead of `CancellationError`.
        }
    }

    /// Serves tunnels in the selected mode until stopped or failed.
    private func serveUntilStopped(
        identity: RemotePairingIdentity,
        identityURL: URL,
        sessionGate: TunnelAgentSessionGate? = nil
    ) async throws {
        if reconnect {
            try await runReconnectLoop(
                identity: identity,
                identityURL: identityURL,
                sessionGate: sessionGate
            )
            return
        }

        let cycle = try await establishTunnelCycle(
            identity: identity,
            identityURL: identityURL,
            pinnedDeviceIdentifier: nil,
            requestedGatewayPort: gatewayPort,
            emitLifecycleEvents: false
        )
        try await serve(cycle)
    }

    /// Serves one established tunnel until it closes, then releases it.
    private func serve(_ cycle: TunnelCycle) async throws {
        defer {
            cycle.gateway.close()
            cycle.session.close()
        }
        let statsReporter = startTunnelStatisticsReporter(
            network: cycle.network,
            interval: statsInterval
        )
        defer {
            statsReporter?.cancel()
        }

        let gateway = cycle.gateway
        try await withTaskCancellationHandler {
            try await gateway.waitUntilClosed()
        } onCancel: {
            gateway.close()
        }
    }

    /// Keeps one device's tunnel alive across drops, reporting transitions.
    private func runReconnectLoop(
        identity: RemotePairingIdentity,
        identityURL: URL,
        sessionGate: TunnelAgentSessionGate? = nil
    ) async throws {
        // Pins the loop to one physical device and one local port after the
        // first healthy cycle, so reconnection can neither hop devices on a
        // multi-device host nor move the gateway endpoint under clients.
        let pinned = PinnedTunnelTarget(
            deviceIdentifier: connection.udid,
            gatewayPort: gatewayPort
        )
        try await TunnelReconnectLoop.run(
            backoff: Self.reconnectBackoff,
            waitBeforeAttempt: { delay in
                let outcome = try await TunnelReconnectLoop.waitForReattach(
                    of: pinned.deviceIdentifier,
                    upTo: delay,
                    deviceEvents: {
                        DeviceClient().deviceEvents()
                    }
                )
                if outcome == .reattached {
                    writeTunnelProgress(
                        "Device attached; retrying without waiting out the backoff delay."
                    )
                }
            },
            emit: { event in
                // Waiting IPC requests fail with this reason when the
                // tunnel stays down past their patience. Both event kinds
                // carry a reason because a tunnel that never establishes
                // reports its failures through re-establishing alone.
                switch event {
                case .tunnelLost(let reason),
                     .reestablishing(_, _, let reason):
                    sessionGate?.markLost(reason: reason)
                }
                writeTunnelLifecycleEvent(
                    event,
                    deviceIdentifier: pinned.deviceIdentifier
                )
            },
            establishAndServe: { onReady in
                let cycle = try await establishTunnelCycle(
                    identity: identity,
                    identityURL: identityURL,
                    pinnedDeviceIdentifier: pinned.deviceIdentifier,
                    requestedGatewayPort: pinned.gatewayPort,
                    emitLifecycleEvents: true
                )
                pinned.pin(
                    deviceIdentifier: cycle.deviceIdentifier,
                    gatewayPort: cycle.gateway.port
                )
                onReady()
                try await serve(cycle, sessionGate: sessionGate)
            }
        )
    }

    /// Serves one tunnel cycle, sharing one RSD session with IPC handlers.
    ///
    /// The shared session rides the cycle's own packet network, so operations
    /// skip both the spawn and the discovery handshake that the per-operation
    /// exec path pays. It lives exactly as long as the cycle. Handlers
    /// receive it once the tunnel is ready and lose it when the cycle ends.
    private func serve(
        _ cycle: TunnelCycle,
        sessionGate: TunnelAgentSessionGate?
    ) async throws {
        guard let sessionGate else {
            try await serve(cycle)
            return
        }
        let shared = try await DeviceClient().connect(
            toRemoteServicesUsing: cycle.network,
            discoveryPort: cycle.network.configuration.serviceDiscoveryPort,
            label: "rorkdevice-agent"
        )
        sessionGate.publish(shared)
        defer {
            // The reason arrives with the loop's tunnel-lost event right
            // after this teardown. Passing nil keeps the gate's last
            // known reason.
            sessionGate.markLost(reason: nil)
            shared.close()
        }
        try await serve(cycle)
    }

    /// Establishes one complete tunnel: session, packet network, gateway,
    /// remote-pairing trust, and the `ready` stdout event.
    ///
    /// Everything created for the cycle is released when any later step fails,
    /// so a retrying caller cannot accumulate half-built tunnels.
    private func establishTunnelCycle(
        identity: RemotePairingIdentity,
        identityURL: URL,
        pinnedDeviceIdentifier: String?,
        requestedGatewayPort: UInt16,
        emitLifecycleEvents: Bool
    ) async throws -> TunnelCycle {
        var options = connection
        options.udid = pinnedDeviceIdentifier ?? connection.udid
        let connected = try await options.connectedSession(
            label: "rorkdevice-tunnel"
        )
        writeTunnelProgress(
            "Opened Lockdown session for \(connected.deviceIdentifier)."
        )
        do {
            return try await establishTunnelCycle(
                for: connected,
                identity: identity,
                identityURL: identityURL,
                requestedGatewayPort: requestedGatewayPort,
                emitLifecycleEvents: emitLifecycleEvents
            )
        } catch {
            connected.session.close()
            throw error
        }
    }

    /// Continues cycle establishment once a Lockdown session exists.
    private func establishTunnelCycle(
        for connected: (session: DeviceSession, deviceIdentifier: String),
        identity: RemotePairingIdentity,
        identityURL: URL,
        requestedGatewayPort: UInt16,
        emitLifecycleEvents: Bool
    ) async throws -> TunnelCycle {
        let tunnel = try await connected.session.openCoreDeviceTunnel(
            requestedMaximumTransmissionUnit:
                maximumTransmissionUnit
        )
        writeTunnelProgress(
            "Negotiated CoreDevice tunnel to \(tunnel.configuration.deviceAddress):\(tunnel.configuration.serviceDiscoveryPort) with MTU \(tunnel.configuration.maximumTransmissionUnit)."
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
            gateway = try await startGateway(
                network: network,
                requestedPort: requestedGatewayPort
            )
        } catch {
            network.close()
            throw error
        }
        writeTunnelProgress(
            "Listening on \(gateway.host):\(gateway.port)."
        )

        do {
            try await RemotePairingTrust.establishIfNeeded(
                for: identity,
                using: network,
                discoveryPort:
                    network.configuration.serviceDiscoveryPort,
                progress: { progress in
                    writeRemotePairingProgress(progress)
                    if emitLifecycleEvents, progress == .enrollingIdentity {
                        writeTunnelStdoutLine(
                            TunnelWaitingForTrustEvent(
                                udid: connected.deviceIdentifier
                            )
                        )
                    }
                }
            )
            try writeTunnelReadyEvent(
                deviceIdentifier: connected.deviceIdentifier,
                identityPath: identityURL.path,
                network: network,
                gateway: gateway,
                capabilities: serve ? TunnelStartCommand.serveCapabilities : nil
            )
        } catch {
            gateway.close()
            throw error
        }

        return TunnelCycle(
            deviceIdentifier: connected.deviceIdentifier,
            session: connected.session,
            network: network,
            gateway: gateway
        )
    }

    /// Binds the gateway, falling back to an ephemeral port when a previous
    /// cycle's port has been taken in the meantime and the caller never
    /// demanded a specific one.
    private func startGateway(
        network: CoreDeviceUserspaceNetwork,
        requestedPort: UInt16
    ) async throws -> CoreDeviceUserspaceGateway {
        // Only a port borrowed from an earlier cycle may fall back, because
        // a fixed `--gateway-port` must fail loudly and an ephemeral request
        // has nothing to fall back from.
        let borrowedEphemeralPort = gatewayPort == 0 && requestedPort != 0
        do {
            return try await CoreDeviceUserspaceGateway.start(
                network: network,
                host: gatewayHost,
                port: requestedPort
            )
        } catch is CoreDeviceUserspaceGateway.PortUnavailableError
            where borrowedEphemeralPort
        {
            writeTunnelProgress(
                "Local port \(requestedPort) is no longer available; selecting a new ephemeral port."
            )
            return try await CoreDeviceUserspaceGateway.start(
                network: network,
                host: gatewayHost,
                port: 0
            )
        }
    }
}

/// One fully established tunnel and the resources serving it.
private struct TunnelCycle {
    let deviceIdentifier: String
    let session: DeviceSession
    let network: CoreDeviceUserspaceNetwork
    let gateway: CoreDeviceUserspaceGateway
}

/// Device and local-port choice that reconnection must keep honoring.
///
/// A plain lock box. The reconnect loop's closures run sequentially but are
/// escaping, so shared mutable state needs an explicitly synchronized home.
private final class PinnedTunnelTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var _deviceIdentifier: String?
    private var _gatewayPort: UInt16

    init(deviceIdentifier: String?, gatewayPort: UInt16) {
        _deviceIdentifier = deviceIdentifier
        _gatewayPort = gatewayPort
    }

    var deviceIdentifier: String? {
        lock.withLock { _deviceIdentifier }
    }

    var gatewayPort: UInt16 {
        lock.withLock { _gatewayPort }
    }

    func pin(deviceIdentifier: String, gatewayPort: UInt16) {
        lock.withLock {
            _deviceIdentifier = deviceIdentifier
            _gatewayPort = gatewayPort
        }
    }
}

/// Periodically writes tunnel data-plane statistics to stderr.
///
/// Returns `nil` when the interval is zero, keeping statistics opt-in.
private func startTunnelStatisticsReporter(
    network: CoreDeviceUserspaceNetwork,
    interval: UInt32
) -> Task<Void, Never>? {
    guard interval > 0 else {
        return nil
    }
    return Task {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            writeTunnelProgress(
                tunnelStatisticsLine(network.statistics())
            )
        }
    }
}

/// Formats one machine-parseable statistics line for tunnel diagnostics.
func tunnelStatisticsLine(
    _ statistics: CoreDeviceUserspaceNetworkStatistics
) -> String {
    "Tunnel stats: "
        + "packetsOut=\(statistics.packetsSent) "
        + "bytesOut=\(statistics.bytesSent) "
        + "packetsIn=\(statistics.packetsReceived) "
        + "bytesIn=\(statistics.bytesReceived) "
        + "connections=\(statistics.activeConnections) "
        + "tcpTx=\(statistics.tcpSegmentsSent) "
        + "tcpRx=\(statistics.tcpSegmentsReceived) "
        + "tcpRexmit=\(statistics.tcpSegmentsRetransmitted) "
        + "tcpDrops=\(statistics.tcpDrops) "
        + "tcpErrors=\(statistics.tcpErrors) "
        + "ip6Out=\(statistics.ip6PacketsSent) "
        + "ip6In=\(statistics.ip6PacketsReceived) "
        + "ip6Drops=\(statistics.ip6Drops)."
}

/// Machine-readable event emitted once a tunnel can accept local clients.
struct TunnelReadyEvent: Encodable {
    let event = "ready"
    let address: String
    let rsdPort: UInt16
    let udid: String
    let userspaceTun = true
    let userspaceTunHost: String
    let userspaceTunPort: UInt16
    let identityPath: String
    let mtu: UInt16

    /// Operations the agent's serving loop accepts on standard input, or nil
    /// outside serving mode. Supervisors route an operation through the pipe
    /// only when it is listed here.
    let capabilities: [String]?
}

/// Reconnect-mode stdout line for a tunnel lifecycle transition.
///
/// `tunnel-lost` reports why a ready tunnel died. `re-establishing` announces
/// the next attempt with its schedule position and the latest failure. The
/// device is omitted while no cycle has identified one yet.
struct TunnelLifecycleEventLine: Encodable {
    let event: TunnelReconnectLoop.Event
    let udid: String?

    private enum CodingKeys: String, CodingKey {
        case event
        case udid
        case reason
        case attempt
        case delayMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(udid, forKey: .udid)
        switch event {
        case .tunnelLost(let reason):
            try container.encode("tunnel-lost", forKey: .event)
            try container.encode(reason, forKey: .reason)
        case .reestablishing(let attempt, let delay, let reason):
            try container.encode("re-establishing", forKey: .event)
            try container.encode(attempt, forKey: .attempt)
            try container.encode(
                wholeMilliseconds(of: delay),
                forKey: .delayMs
            )
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Reconnect-mode stdout line telling hosts an approval prompt is pending.
///
/// Emitted when enrollment starts waiting on the device's Trust dialog, so
/// supervisors extend their patience instead of restarting the tunnel in the
/// middle of the user's approval window.
struct TunnelWaitingForTrustEvent: Encodable {
    let event = "waiting-for-trust"
    let udid: String?
}

/// Converts a duration to whole milliseconds for JSON transport.
private func wholeMilliseconds(of duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds) * 1_000
        + Int(components.attoseconds / 1_000_000_000_000_000)
}

/// Writes one reconnect lifecycle transition to machine-readable stdout.
private func writeTunnelLifecycleEvent(
    _ event: TunnelReconnectLoop.Event,
    deviceIdentifier: String?
) {
    writeTunnelStdoutLine(
        TunnelLifecycleEventLine(event: event, udid: deviceIdentifier)
    )
}

/// Writes one newline-delimited ready event without stdout buffering.
private func writeTunnelReadyEvent(
    deviceIdentifier: String,
    identityPath: String,
    network: CoreDeviceUserspaceNetwork,
    gateway: CoreDeviceUserspaceGateway,
    capabilities: [String]?
) throws {
    let event = TunnelReadyEvent(
        address: network.configuration.deviceAddress,
        rsdPort: network.configuration.serviceDiscoveryPort,
        udid: deviceIdentifier,
        userspaceTunHost: gateway.host,
        userspaceTunPort: gateway.port,
        identityPath: identityPath,
        mtu: network.configuration.maximumTransmissionUnit,
        capabilities: capabilities
    )
    try MachineReadableOutput.standardOutput.writeLine(JSONEncoder().encode(event))
}

/// Writes newline-terminated machine-readable lines without interleaving.
///
/// Ready events, lifecycle events, and serving replies all share standard
/// output. Concurrent writers hold one lock per complete line, so a consumer
/// that frames on newlines never sees two lines spliced together.
final class MachineReadableOutput: @unchecked Sendable {
    static let standardOutput = MachineReadableOutput(handle: .standardOutput)

    private let lock = NSLock()
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Appends the newline terminator and writes the whole line atomically
    /// with respect to every other writer sharing this instance.
    func writeLine(_ line: Data) throws {
        var data = line
        data.append(0x0a)
        try lock.withLock {
            try handle.write(contentsOf: data)
        }
    }
}

/// Writes one serving-loop reply line to machine-readable standard output.
private func writeAgentReplyLine(_ line: Data) {
    try? MachineReadableOutput.standardOutput.writeLine(line)
}

/// Best-effort NDJSON writer for reconnect-mode lifecycle lines.
///
/// Unlike the initial `ready` line, lifecycle transitions are advisory. A
/// host that stopped reading stdout must not be able to kill the tunnel with
/// a write failure, so encoding or pipe errors are swallowed.
private func writeTunnelStdoutLine(_ line: some Encodable) {
    guard let data = try? JSONEncoder().encode(line) else {
        return
    }
    try? MachineReadableOutput.standardOutput.writeLine(data)
}

/// Writes human-readable tunnel progress separately from machine-readable stdout.
private func writeTunnelProgress(_ message: String) {
    guard let data = "rorkdevice: \(message)\n".data(using: .utf8) else {
        return
    }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// Converts typed trust phases into concise operator-facing CLI diagnostics.
func writeRemotePairingProgress(
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
            try CommandOutput.write(
                contentsOf: lockdownInfoJSON(info)
            )
            try CommandOutput.write(
                contentsOf: Data([0x0a])
            )
            return
        }
        CommandOutput.print("UDID: \(info.uniqueDeviceID ?? "-")")
        CommandOutput.print("Name: \(info.deviceName ?? "-")")
        CommandOutput.print("Product: \(info.productType ?? "-")")
        CommandOutput.print("Version: \(info.productVersion ?? "-")")
        CommandOutput.print("Build: \(info.buildVersion ?? "-")")
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

    @Flag(help: "Emit entry names as a JSON array.")
    var json = false

    @Argument(help: "Remote directory path.")
    var path: String = "/"

    func run() async throws {
        let afc = try await access.afcClient()
        let entries = try await afc.directoryContents(at: path)
        if json {
            try CommandOutput.write(
                contentsOf: fileListJSON(entries)
            )
            try CommandOutput.write(contentsOf: Data([0x0a]))
            return
        }
        for name in entries {
            CommandOutput.print(name)
        }
    }
}

/// Encodes remote directory entries for machine-readable CLI consumers.
///
/// Entry names are emitted exactly as AFC reports them, including `"."` and
/// `".."`, so JSON output preserves the same semantics as the default
/// line-oriented representation.
func fileListJSON(_ entries: [String]) throws -> Data {
    try JSONEncoder().encode(entries)
}

/// Prints metadata for a remote path.
struct FilesInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print remote path metadata."
    )

    @OptionGroup var access: FileAccessOptions

    @Flag(help: "Emit AFC metadata as a JSON object.")
    var json = false

    @Argument(help: "Remote path.")
    var path: String

    func run() async throws {
        let afc = try await access.afcClient()
        let info = try await afc.fileInfo(at: path)
        if json {
            try CommandOutput.write(
                contentsOf: fileInfoJSON(info)
            )
            try CommandOutput.write(contentsOf: Data([0x0a]))
            return
        }
        for key in info.values.keys.sorted() {
            CommandOutput.print("\(key): \(info.values[key] ?? "")")
        }
    }
}

/// Encodes the complete AFC metadata dictionary for automation clients.
///
/// Raw AFC field names remain intact so callers can consume protocol fields
/// introduced by newer iOS versions without requiring a matching CLI release.
func fileInfoJSON(_ info: AFCFileInfo) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(info.values)
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

/// Lists installed applications through InstallationProxy.
struct AppsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed apps."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(help: "Application type: user, system, internal, or all.")
    var type: ApplicationType = .user

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func run() async throws {
        let session = try await connection.session()
        let apps = try await session.installedApplications(matching: type)
        if json {
            try CommandOutput.write(
                contentsOf: installedApplicationListJSON(apps)
            )
            try CommandOutput.write(contentsOf: Data([0x0a]))
            return
        }
        for app in apps {
            let identifier = app.bundleIdentifier ?? "-"
            let name = app.displayName ?? "-"
            CommandOutput.print("\(identifier)\t\(name)")
        }
    }
}

/// Encodes installed applications for machine-readable CLI consumers.
///
/// The JSON representation exposes stable, commonly used bundle metadata
/// without coupling callers to raw InstallationProxy records.
func installedApplicationListJSON(
    _ applications: [InstalledApplication]
) throws -> Data {
    let entries = applications.map(InstalledApplicationListEntry.init)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(entries)
}

/// Stable application metadata emitted by `apps list --json` and by the
/// tunnel agent's `apps-list` operation.
struct InstalledApplicationListEntry: Encodable, Sendable {
    /// Bundle identifier used to address the application on the device.
    let bundleIdentifier: String?

    /// Human-readable application name when supplied by the device service.
    let displayName: String?

    /// Marketing version from `CFBundleShortVersionString`.
    let version: String?

    /// Build version from `CFBundleVersion`.
    let buildVersion: String?

    /// Creates a CLI entry from the backend-neutral installed-app model.
    init(_ application: InstalledApplication) {
        bundleIdentifier = application.bundleIdentifier
        displayName = application.displayName
        version = application.version
        buildVersion = application.buildVersion
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
                CommandOutput.print("\(event.status) \(percent)%")
            } else {
                CommandOutput.print(event.status)
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
            CommandOutput.print(event.status)
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
        CommandOutput.print(processIdentifier)
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
        CommandOutput.print(terminated ? "Terminated." : "Application is not running.")
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
            CommandOutput.print(url.path)
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
