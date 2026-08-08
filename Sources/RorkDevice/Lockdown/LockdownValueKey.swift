import Foundation

/// An open Lockdown key whose generic argument declares the expected value type.
///
/// The optional domain participates in the key's identity because equal wire
/// names can carry different meaning in different Lockdown domains. This shape
/// remains separate from domainless service registries.
public struct LockdownValueKey<Value>:
    Hashable,
    Sendable,
    ExpressibleByStringLiteral
{
    /// Wire name sent in the Lockdown request.
    public let rawValue: String

    /// Optional Lockdown preference domain containing the key.
    public let domain: String?

    /// Creates a key in the default or a named Lockdown domain.
    ///
    /// - Parameters:
    ///   - rawValue: Wire name accepted by Lockdown.
    ///   - domain: Optional preference domain containing the key.
    public init(
        _ rawValue: String,
        domain: String? = nil
    ) {
        self.rawValue = rawValue
        self.domain = domain
    }

    /// Creates a default-domain key from a string literal.
    ///
    /// - Parameter value: Wire name accepted by Lockdown.
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

public extension LockdownValueKey where Value == String {
    /// Unique device identifier.
    static var uniqueDeviceID: Self {
        Self("UniqueDeviceID")
    }

    /// Human-readable device name.
    static var deviceName: Self {
        Self("DeviceName")
    }

    /// Hardware product type.
    static var productType: Self {
        Self("ProductType")
    }

    /// Operating-system product version.
    static var productVersion: Self {
        Self("ProductVersion")
    }

    /// Operating-system build version.
    static var buildVersion: Self {
        Self("BuildVersion")
    }

    /// Wi-Fi hardware address.
    static var wiFiAddress: Self {
        Self("WiFiAddress")
    }
}

public extension LockdownValueKey where Value == Data {
    /// Public key used to establish host pairing.
    static var devicePublicKey: Self {
        Self("DevicePublicKey")
    }
}

public extension LockdownValueKey where Value == Bool {
    /// Developer Mode state in the AMFI preference domain.
    static var developerModeStatus: Self {
        Self(
            "DeveloperModeStatus",
            domain: "com.apple.security.mac.amfi"
        )
    }

    /// Wireless Lockdown connection state.
    static var wirelessConnectionsEnabled: Self {
        Self(
            "EnableWifiConnections",
            domain: "com.apple.mobile.wireless_lockdown"
        )
    }
}
