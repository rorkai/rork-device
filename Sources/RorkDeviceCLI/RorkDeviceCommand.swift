import ArgumentParser
import Foundation
import RorkDevice

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

struct ConnectionOptions: ParsableArguments {
    @Option(help: "Device UDID. Defaults to the first discovered device.")
    var udid: String?

    @Option(help: "Direct Lockdown host. When provided, usbmuxd discovery is skipped.")
    var host: String?

    @Option(help: "Direct Lockdown port.")
    var port: UInt16 = 62078

    @Option(help: "Existing Lockdown pairing record plist.")
    var pairingRecord: String?

    func pairingRecordValue() throws -> PairingRecord {
        guard let pairingRecord else {
            throw ValidationError("--pairing-record is required for this command.")
        }
        return try PairingRecord.load(from: URL(fileURLWithPath: pairingRecord))
    }

    func session(label: String = "rorkdevice") async throws -> DeviceSession {
        let client = DeviceClient()
        let pairing = try pairingRecordValue()
        if let host {
            return try await client.directSession(host: host, port: port, pairingRecord: pairing, label: label)
        }

        let devices = try await client.devices()
        let selected: Device?
        if let udid {
            selected = devices.first { $0.identifier == udid }
        } else {
            selected = devices.first
        }
        guard let selected else {
            throw ValidationError("No matching device found.")
        }
        return try await client.session(for: selected, pairingRecord: pairing, label: label)
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List devices reported by local usbmuxd."
    )

    func run() async throws {
        let devices = try await DeviceClient().devices()
        if devices.isEmpty {
            print("No devices found.")
            return
        }
        for device in devices {
            print(device.identifier)
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print basic Lockdown device information."
    )

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let session = try await connection.session()
        let info = try await session.deviceInfo()
        print("UDID: \(info.uniqueDeviceID ?? "-")")
        print("Name: \(info.deviceName ?? "-")")
        print("Product: \(info.productType ?? "-")")
        print("Version: \(info.productVersion ?? "-")")
        print("Build: \(info.buildVersion ?? "-")")
    }
}

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Manage installed apps.",
        subcommands: [AppsList.self]
    )
}

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
        let apps = try await session.applications(type: type)
        for app in apps {
            let identifier = app["CFBundleIdentifier"] as? String ?? "-"
            let name = app["CFBundleDisplayName"] as? String ?? app["CFBundleName"] as? String ?? "-"
            print("\(identifier)\t\(name)")
        }
    }
}

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
            ipaURL: URL(fileURLWithPath: ipaPath),
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

struct Profiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Manage provisioning profiles.",
        subcommands: [ProfilesInstall.self]
    )
}

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
        try await session.installProvisioningProfile(at: URL(fileURLWithPath: profilePath))
    }
}

extension ApplicationType: ExpressibleByArgument {
    /// Creates an application-type filter from the CLI argument value.
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
