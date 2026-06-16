import Foundation

/// Application class filter used when listing installed applications.
///
/// The raw values match InstallationProxy's `Browse` protocol. RSD-backed
/// sessions derive the same classes from CoreDevice metadata so callers can use
/// one filter across both service backends.
public enum ApplicationType: String, Sendable {
    /// User-installed applications visible to normal app-management flows.
    case user = "User"

    /// Built-in system applications.
    case system = "System"

    /// Internal applications exposed by devices that support this class.
    case internalApplications = "Internal"

    /// Every application class supported by the connected device.
    case all = "Any"
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

/// InstallationProxy operation error.
///
/// InstallationProxy reports failures as a protocol code plus an optional
/// human-readable message. This value keeps those fields together so progress
/// handlers and thrown errors expose one coherent failure object.
public struct InstallationError: Equatable, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    /// InstallationProxy operation error code.
    ///
    /// Codes are protocol strings and may change across iOS releases. This
    /// wrapper keeps common values readable in Swift while preserving unknown
    /// codes through `rawValue`.
    public struct Code: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
        /// Raw error code reported by InstallationProxy.
        public let rawValue: String

        /// Creates an error code from a raw InstallationProxy string.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Printable error code.
        public var description: String {
            rawValue
        }

        /// InstallationProxy rejected the package during application verification.
        public static let applicationVerificationFailed = Self(rawValue: "ApplicationVerificationFailed")

        /// InstallationProxy could not find the staged package path.
        public static let packageNotFound = Self(rawValue: "PackageNotFound")

        /// InstallationProxy received an invalid command or client option.
        public static let invalidCommand = Self(rawValue: "InvalidCommand")
    }

    /// Protocol error code reported by InstallationProxy.
    public let code: Code

    /// Optional human-readable message paired with `code`.
    public let message: String?

    /// Creates an InstallationProxy error from decoded protocol fields.
    public init(code: Code, message: String? = nil) {
        self.code = code
        self.message = message
    }

    /// Creates an InstallationProxy error from a raw protocol code string.
    public init(code rawCode: String, message: String? = nil) {
        self.init(code: Code(rawValue: rawCode), message: message)
    }

    /// Human-readable error text suitable for logs and CLI output.
    public var description: String {
        if let message, !message.isEmpty {
            return "\(code): \(message)"
        }
        return code.description
    }

    /// Localized error text surfaced through Swift and Objective-C error APIs.
    public var errorDescription: String? {
        description
    }
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

    /// Optional operation error. When this is present, high-level install and
    /// uninstall helpers throw `RorkDeviceError.installationProxy`.
    public let error: InstallationError?

    /// Creates an installation progress event from decoded protocol fields.
    public init(
        status: InstallationStatus,
        percentComplete: Int? = nil,
        error: InstallationError? = nil
    ) {
        self.status = status
        self.percentComplete = percentComplete
        self.error = error
    }
}

/// Callback invoked for each InstallationProxy progress event.
///
/// The callback is executed on the task that is reading the device connection.
/// Keep work in the callback lightweight and dispatch elsewhere for UI updates
/// or expensive logging.
public typealias InstallationProgressHandler = @Sendable (InstallationProgress) -> Void
