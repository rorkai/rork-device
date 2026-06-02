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
            Info.self,
            Apps.self,
            Install.self,
            Uninstall.self,
            Profiles.self,
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

    @Option(help: "Existing Lockdown pairing record plist.")
    var pairingRecord: String?

    /// Rejects connection-option combinations that cannot be honored together.
    func validate() throws {
        try validateConnectionOptions()
    }

    /// Loads and validates the pairing record option.
    func pairingRecordValue() throws -> PairingRecord {
        guard let pairingRecord else {
            throw ValidationError("--pairing-record is required for this command.")
        }
        return try PairingRecord.load(from: URL(fileURLWithPath: pairingRecord))
    }

    /// Opens a direct or usbmux-backed session from parsed CLI options.
    func session(label: String = "rorkdevice") async throws -> DeviceSession {
        try validateConnectionOptions()
        let client = DeviceClient()
        let pairing = try pairingRecordValue()
        if let host {
            return try await client.connect(host: host, port: port, using: pairing, label: label)
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
        return try await client.connect(to: selected, using: pairing, label: label)
    }

    /// Shared implementation for parse-time and runtime connection validation.
    private func validateConnectionOptions() throws {
        if host != nil, udid != nil {
            throw ValidationError("--udid cannot be used with --host because direct Lockdown connections skip usbmux discovery.")
        }
        if host == nil, port != 62078 {
            throw ValidationError("--port requires --host.")
        }
    }
}

/// Lists devices currently visible through local usbmux.
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List devices reported by local usbmuxd."
    )

    func run() async throws {
        let devices = try await DeviceClient().discoverDevices()
        if devices.isEmpty {
            print("No devices found.")
            return
        }
        for device in devices {
            print(device.identifier)
        }
    }
}

/// Prints common Lockdown information for the selected device.
struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print basic Lockdown device information."
    )

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let session = try await connection.session()
        let info = try await session.fetchDeviceInfo()
        print("UDID: \(info.uniqueDeviceID ?? "-")")
        print("Name: \(info.deviceName ?? "-")")
        print("Product: \(info.productType ?? "-")")
        print("Version: \(info.productVersion ?? "-")")
        print("Build: \(info.buildVersion ?? "-")")
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

    @Option(help: "Application type: User, System, Internal, or Any.")
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
        self.init(rawValue: argument)
    }
}
