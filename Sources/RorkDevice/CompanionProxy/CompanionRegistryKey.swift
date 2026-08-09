/// An open registry key whose generic argument declares the expected value type.
///
/// Known keys provide discoverable static members. Callers can create additional
/// keys when newer device software exposes registry values that this package
/// does not yet model.
///
/// This type remains concrete until another registry service uses the same key
/// shape. Lockdown value keys remain separate because their identity also
/// includes a domain.
public struct CompanionRegistryKey<Value>:
    Hashable,
    RawRepresentable,
    Sendable,
    ExpressibleByStringLiteral
{
    /// Wire name sent to the companion proxy service.
    public let rawValue: String

    /// Creates a key for an arbitrary registry value.
    ///
    /// - Parameter rawValue: Wire name accepted by the companion proxy service.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Creates a key from its wire representation.
    ///
    /// - Parameter rawValue: Wire name accepted by the companion proxy service.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a custom key from a string literal.
    ///
    /// - Parameter value: Wire name accepted by the companion proxy service.
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

public extension CompanionRegistryKey where Value == String {
    /// Creates a custom string-valued registry key.
    static func string(_ rawValue: String) -> Self {
        Self(rawValue)
    }

    /// Human-readable device name.
    static var deviceName: Self {
        Self("DeviceName")
    }

    /// Hardware model number.
    static var modelNumber: Self {
        Self("ModelNumber")
    }
}

public extension CompanionRegistryKey where Value == Int {
    /// Creates a custom integer-valued registry key.
    static func integer(_ rawValue: String) -> Self {
        Self(rawValue)
    }
}

public extension CompanionRegistryKey where Value == Bool {
    /// Creates a custom Boolean-valued registry key.
    static func boolean(_ rawValue: String) -> Self {
        Self(rawValue)
    }
}
