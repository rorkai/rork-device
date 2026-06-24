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
        var clientOptions: [String: Any] = [:]
        if type != .all {
            clientOptions["ApplicationType"] = type.rawValue
        }
        if type == .user || type == .all {
            clientOptions["ShowLaunchProhibitedApps"] = true
        }

        try await PropertyListMessageFramer.send([
            "Command": "Browse",
            "ClientOptions": clientOptions,
        ], to: connection)

        var applicationsByIndex: [Int: [String: Any]] = [:]
        var nextIndex = 0
        while true {
            let response = try await PropertyListMessageFramer.receive(from: connection)
            if let errorCode = response.string("Error") {
                throw RorkDeviceError.installationProxy(
                    InstallationError(
                        code: .init(rawValue: errorCode),
                        message: response.string("ErrorDescription")
                    )
                )
            }

            if let currentList = response["CurrentList"] as? [[String: Any]] {
                if let currentAmount = response.int("CurrentAmount"),
                   currentAmount != currentList.count {
                    throw RorkDeviceError.protocolViolation(
                        "InstallationProxy Browse response CurrentAmount did not match CurrentList."
                    )
                }

                let currentIndex = response.int("CurrentIndex") ?? nextIndex
                guard currentIndex >= 0 else {
                    throw RorkDeviceError.protocolViolation(
                        "InstallationProxy Browse response included a negative CurrentIndex."
                    )
                }
                for (offset, application) in currentList.enumerated() {
                    let (index, indexOverflowed) = currentIndex.addingReportingOverflow(offset)
                    guard !indexOverflowed else {
                        throw RorkDeviceError.protocolViolation(
                            "InstallationProxy Browse response page index overflowed."
                        )
                    }
                    guard applicationsByIndex[index] == nil else {
                        throw RorkDeviceError.protocolViolation(
                            "InstallationProxy Browse response included overlapping application pages."
                        )
                    }
                    applicationsByIndex[index] = application
                }
                let (nextPageIndex, pageRangeOverflowed) = currentIndex.addingReportingOverflow(currentList.count)
                guard !pageRangeOverflowed else {
                    throw RorkDeviceError.protocolViolation(
                        "InstallationProxy Browse response page range overflowed."
                    )
                }
                nextIndex = max(nextIndex, nextPageIndex)
            } else if let currentAmount = response.int("CurrentAmount"),
                      currentAmount != 0 {
                throw RorkDeviceError.protocolViolation(
                    "InstallationProxy Browse response did not include CurrentList."
                )
            }

            guard response.string("Status") == InstallationStatus.complete.rawValue else {
                continue
            }

            let indexes = applicationsByIndex.keys.sorted()
            guard indexes == Array(0 ..< applicationsByIndex.count) else {
                throw RorkDeviceError.protocolViolation(
                    "InstallationProxy Browse response did not include a contiguous application list."
                )
            }
            return indexes.compactMap { applicationsByIndex[$0] }
        }
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
                status: InstallationStatus(rawValue: response.string("Status") ?? InstallationStatus.unknown.rawValue),
                percentComplete: response.int("PercentComplete"),
                error: response.string("Error").map {
                    InstallationError(
                        code: $0,
                        message: response.string("ErrorDescription")
                    )
                }
            )
            progress?(event)

            if let error = event.error {
                throw RorkDeviceError.installationProxy(error)
            }
            if event.status == .complete {
                return
            }
        }
    }
}
