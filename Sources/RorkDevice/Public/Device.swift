import Foundation

/// Device identity and connection route discovered by a transport.
///
/// A `Device` is intentionally lightweight. It is safe to store, display, and
/// pass back into `DeviceClient.connect(to:using:label:)`; it does not
/// keep sockets open and does not prove that the device is still attached.
public struct Device: Equatable, Sendable {
    /// Stable device identifier, normally the device UDID.
    public let identifier: String

    /// Transport route that should be used when opening Lockdown.
    public let connection: DeviceConnectionKind

    /// Raw discovery properties converted to strings for diagnostics.
    ///
    /// usbmux may report additional metadata such as connection type, product
    /// id, location id, and network address details. Values that are not scalar
    /// strings or numbers are omitted.
    public let properties: [String: String]

    /// Creates a device value from a caller-provided transport route.
    ///
    /// This is mainly useful for tests, direct endpoint flows, and integrations
    /// that discover devices outside of `USBMuxClient`.
    public init(identifier: String, connection: DeviceConnectionKind, properties: [String: String] = [:]) {
        self.identifier = identifier
        self.connection = connection
        self.properties = properties
    }
}

/// Route used to open service connections for a device.
public enum DeviceConnectionKind: Equatable, Sendable {
    /// Device is reachable through the local usbmux endpoint.
    ///
    /// `deviceID` is the numeric id assigned by usbmux for the current
    /// attachment. It can change across reconnects, so rediscover before
    /// caching it for long-running workflows.
    case usbmux(deviceID: UInt32)

    /// Device Lockdown endpoint is reachable directly at a host and port.
    ///
    /// Direct routes are useful for tunnel-based flows and protocol tests.
    case direct(host: String, port: UInt16)
}

/// Common Lockdown identity fields for a connected device.
///
/// Lockdown exposes many domains and keys. `DeviceInfo` keeps the fields that
/// are most useful for CLI output and diagnostics while retaining scalar values
/// in `rawValues` for callers that need additional metadata.
public struct DeviceInfo: Equatable, Sendable {
    /// Device UDID reported by Lockdown as `UniqueDeviceID`.
    public let uniqueDeviceID: String?

    /// Human-readable device name shown in Finder/Xcode.
    public let deviceName: String?

    /// Hardware product type, such as `iPhone16,2`.
    public let productType: String?

    /// OS product version, such as `18.5`.
    public let productVersion: String?

    /// OS build version, such as `22F76`.
    public let buildVersion: String?

    /// Scalar Lockdown values converted to strings.
    public let rawValues: [String: String]

    /// Creates a typed summary from a Lockdown `GetValue` dictionary.
    ///
    /// Non-string and non-number values are intentionally excluded from
    /// `rawValues` so the result remains `Sendable` and easy to print.
    public init(values: [String: Any]) {
        uniqueDeviceID = values["UniqueDeviceID"] as? String
        deviceName = values["DeviceName"] as? String
        productType = values["ProductType"] as? String
        productVersion = values["ProductVersion"] as? String
        buildVersion = values["BuildVersion"] as? String
        rawValues = values.compactMapValues { value in
            switch value {
            case let string as String:
                return string
            case let number as NSNumber:
                return number.stringValue
            default:
                return nil
            }
        }
    }
}

/// Installed application metadata returned by InstallationProxy.
///
/// InstallationProxy exposes app records as property-list dictionaries. This
/// value provides typed access to the fields most callers need while retaining
/// scalar raw values for diagnostics and custom workflows.
public struct InstalledApplication: Equatable, Sendable {
    /// Bundle identifier, such as `com.example.app`.
    public let bundleIdentifier: String?

    /// Human-readable display name from `CFBundleDisplayName` or
    /// `CFBundleName`.
    public let displayName: String?

    /// Marketing version from `CFBundleShortVersionString`.
    public let version: String?

    /// Build version from `CFBundleVersion`.
    public let buildVersion: String?

    /// Application type reported by InstallationProxy.
    public let applicationType: String?

    /// Scalar record values converted to sendable diagnostic descriptions.
    public let rawValues: [String: DiagnosticValue]

    /// Creates typed application metadata from a raw InstallationProxy record.
    public init(values: [String: Any]) {
        bundleIdentifier = values["CFBundleIdentifier"] as? String
        displayName = values["CFBundleDisplayName"] as? String ?? values["CFBundleName"] as? String
        version = values["CFBundleShortVersionString"] as? String
        buildVersion = values["CFBundleVersion"] as? String
        applicationType = values["ApplicationType"] as? String
        rawValues = values.mapValues(DiagnosticValue.init)
    }
}
