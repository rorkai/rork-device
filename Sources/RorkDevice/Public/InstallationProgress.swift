import Foundation

/// Application class filter accepted by InstallationProxy `Browse`.
///
/// The raw values match the strings used by the device protocol. They are kept
/// public so callers can reason about the exact request that will be sent.
public enum ApplicationType: String, Sendable {
    /// User-installed applications visible to normal app-management flows.
    case user = "User"

    /// Built-in system applications.
    case system = "System"

    /// Internal applications exposed by devices that support this class.
    case `internal` = "Internal"

    /// Every application class supported by the connected device.
    case any = "Any"
}

/// InstallationProxy operation status.
///
/// Status values are protocol strings and can vary across iOS versions. This
/// type provides named constants for common values while preserving unknown
/// statuses through `rawValue`.
public struct InstallationStatus: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Raw status string reported by InstallationProxy.
    public let rawValue: String

    /// Creates a status from a raw InstallationProxy string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Printable status string.
    public var description: String {
        rawValue
    }

    /// InstallationProxy is creating the app-staging directory.
    public static let creatingStagingDirectory = Self(rawValue: "CreatingStagingDirectory")

    /// InstallationProxy is extracting the IPA package.
    public static let extractingPackage = Self(rawValue: "ExtractingPackage")

    /// InstallationProxy is inspecting package metadata.
    public static let inspectingPackage = Self(rawValue: "InspectingPackage")

    /// InstallationProxy is acquiring the install lock.
    public static let takingInstallLock = Self(rawValue: "TakingInstallLock")

    /// InstallationProxy is preflighting the app before install.
    public static let preflightingApplication = Self(rawValue: "PreflightingApplication")

    /// InstallationProxy is installing the app.
    public static let installing = Self(rawValue: "Installing")

    /// InstallationProxy completed the operation.
    public static let complete = Self(rawValue: "Complete")

    /// Status used when the device response does not include a status field.
    public static let unknown = Self(rawValue: "Unknown")
}

/// Status event emitted while InstallationProxy performs an operation.
///
/// InstallationProxy streams plist dictionaries until an operation completes or
/// fails. `InstallationProgress` preserves the common fields while leaving
/// operation-specific details to lower-level clients if callers need them.
public struct InstallationProgress: Equatable, Sendable {
    /// Operation status reported by the device, such as `CreatingStagingDirectory`,
    /// `Installing`, or `Complete`.
    public let status: InstallationStatus

    /// Optional completion percentage reported by newer InstallationProxy
    /// responses.
    public let percentComplete: Int?

    /// Optional protocol error name. When this is present, high-level install
    /// and uninstall helpers throw `RorkDeviceError.installationProxy`.
    public let errorName: String?

    /// Optional human-readable error description paired with `errorName`.
    public let errorDescription: String?

    /// Creates an installation progress event from decoded protocol fields.
    public init(status: InstallationStatus, percentComplete: Int?, errorName: String?, errorDescription: String?) {
        self.status = status
        self.percentComplete = percentComplete
        self.errorName = errorName
        self.errorDescription = errorDescription
    }
}

/// Callback invoked for each InstallationProxy progress event.
///
/// The callback is executed on the task that is reading the device connection.
/// Keep work in the callback lightweight and dispatch elsewhere for UI updates
/// or expensive logging.
public typealias InstallationProgressHandler = @Sendable (InstallationProgress) -> Void
