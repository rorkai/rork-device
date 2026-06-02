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

/// Status event emitted while InstallationProxy performs an operation.
///
/// InstallationProxy streams plist dictionaries until an operation completes or
/// fails. `InstallationProgress` preserves the common fields while leaving
/// operation-specific details to lower-level clients if callers need them.
public struct InstallationProgress: Equatable, Sendable {
    /// Operation status reported by the device, such as `CreatingStagingDirectory`,
    /// `Installing`, or `Complete`.
    public let status: String

    /// Optional completion percentage reported by newer InstallationProxy
    /// responses.
    public let percentComplete: Int?

    /// Optional protocol error name. When this is present, high-level install
    /// and uninstall helpers throw `RorkDeviceError.installationProxy`.
    public let errorName: String?

    /// Optional human-readable error description paired with `errorName`.
    public let errorDescription: String?

    /// Creates an installation progress event from decoded protocol fields.
    public init(status: String, percentComplete: Int?, errorName: String?, errorDescription: String?) {
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
