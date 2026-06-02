import Foundation

/// Client for the `com.apple.mobile.installation_proxy` service.
///
/// InstallationProxy is responsible for browsing installed applications and for
/// installing or uninstalling apps from paths that have already been staged on
/// the device. Use `DeviceSession.installApplication` for the common AFC +
/// InstallationProxy sequence, or use this client directly for custom commands.
public final class InstallationProxyClient {
    private let connection: DeviceConnection

    /// Creates an InstallationProxy client over an existing service connection.
    ///
    /// The connection should come from
    /// `DeviceSession.startService(.installationProxy)` or an equivalent
    /// transport that has already applied any required secure-service upgrade.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Lists applications matching an application type.
    ///
    /// - Parameter type: Application class to request from the device.
    /// - Returns: Typed application metadata values.
    public func applications(matching type: ApplicationType = .user) async throws -> [InstalledApplication] {
        try await rawApplications(matching: type).map(InstalledApplication.init(values:))
    }

    /// Lists raw application records matching an application type.
    ///
    /// Use this escape hatch when a workflow needs fields not yet modeled by
    /// `InstalledApplication`.
    ///
    /// - Parameter type: Application class to request from the device.
    /// - Returns: Raw application dictionaries returned in `CurrentList`.
    public func rawApplications(matching type: ApplicationType = .user) async throws -> [[String: Any]] {
        try await PropertyListMessageFramer.send([
            "Command": "Browse",
            "ClientOptions": [
                "ApplicationType": type.rawValue,
            ],
        ], to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)
        if let currentList = response["CurrentList"] as? [[String: Any]] {
            return currentList
        }
        if let currentAmount = response.int("CurrentAmount"), currentAmount == 0 {
            return []
        }
        throw RorkDeviceError.protocolViolation("InstallationProxy Browse response did not include CurrentList.")
    }

    /// Installs a package already staged on the device.
    ///
    /// `packagePath` is normally a path in `/PublicStaging` uploaded through
    /// AFC. The progress callback receives every status event until
    /// InstallationProxy reports `Complete` or returns an error.
    ///
    /// - Parameters:
    ///   - packagePath: Device-side path to the staged IPA.
    ///   - bundleIdentifier: Optional expected bundle identifier.
    ///   - progress: Optional progress/event callback.
    public func install(
        packagePath: String,
        bundleIdentifier: String? = nil,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        var clientOptions: [String: Any] = [:]
        if let bundleIdentifier {
            clientOptions["CFBundleIdentifier"] = bundleIdentifier
        }
        try await performCommand([
            "Command": "Install",
            "PackagePath": packagePath,
            "ClientOptions": clientOptions,
        ], progress: progress)
    }

    /// Uninstalls an application by bundle identifier.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to remove.
    ///   - progress: Optional progress/event callback.
    public func uninstall(
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        try await performCommand([
            "Command": "Uninstall",
            "ApplicationIdentifier": bundleIdentifier,
        ], progress: progress)
    }

    /// Sends an InstallationProxy command and streams status events to completion.
    private func performCommand(_ command: [String: Any], progress: InstallationProgressHandler?) async throws {
        try await PropertyListMessageFramer.send(command, to: connection)
        while true {
            let response = try await PropertyListMessageFramer.receive(from: connection)
            let event = InstallationProgress(
                status: response.string("Status") ?? "Unknown",
                percentComplete: response.int("PercentComplete"),
                errorName: response.string("Error"),
                errorDescription: response.string("ErrorDescription")
            )
            progress?(event)

            if let error = event.errorName {
                throw RorkDeviceError.installationProxy(name: error, description: event.errorDescription)
            }
            if event.status == "Complete" {
                return
            }
        }
    }
}
