import Foundation

/// Existing Lockdown pairing record used to authenticate with a device.
///
/// A pairing record is the trust material created when a host pairs with an iOS
/// device. `rork-device` 0.1.0 reads this material and uses it for
/// `StartSession`; it does not create new pairings yet.
///
/// The parser accepts standard plist data and preserves a diagnostic view of
/// unknown fields in `rawValues` so platform-specific records can be inspected
/// without losing compatibility.
public struct PairingRecord: Equatable, Sendable {
    /// Device UDID associated with the pairing record.
    public let udid: String

    /// Host identifier sent to Lockdown in `StartSession`.
    public let hostID: String

    /// System BUID sent to Lockdown in `StartSession`.
    public let systemBUID: String

    /// Device certificate used by secure-session implementations.
    public let deviceCertificate: Data?

    /// Host certificate used by secure-session implementations.
    public let hostCertificate: Data?

    /// Host private key used by secure-session implementations.
    public let hostPrivateKey: Data?

    /// Root certificate used by secure-session implementations.
    public let rootCertificate: Data?

    /// Root private key used by secure-session implementations.
    public let rootPrivateKey: Data?

    /// Escrow bag data when present in the pairing record.
    public let escrowBag: Data?

    /// Raw plist values converted to stable diagnostic descriptions.
    public let rawValues: [String: DiagnosticValue]

    /// Loads a pairing record from a plist file.
    ///
    /// - Parameter fileURL: File URL containing a standard pairing-record plist.
    /// - Throws: `RorkDeviceError.invalidPairingRecord` when required fields
    ///   are missing or empty.
    public static func load(from fileURL: URL) throws -> PairingRecord {
        try parse(Data(contentsOf: fileURL))
    }

    /// Parses a pairing record from plist data.
    ///
    /// - Parameter data: XML or binary plist bytes.
    /// - Returns: A normalized pairing record with required Lockdown fields.
    public static func parse(_ data: Data) throws -> PairingRecord {
        guard let dictionary = try PropertyListCodec.decode(data) as? [String: Any] else {
            throw RorkDeviceError.invalidPairingRecord("Expected plist dictionary.")
        }

        return PairingRecord(
            udid: try requiredString("UDID", in: dictionary),
            hostID: try requiredString("HostID", in: dictionary),
            systemBUID: try requiredString("SystemBUID", in: dictionary),
            deviceCertificate: dataValue("DeviceCertificate", in: dictionary),
            hostCertificate: dataValue("HostCertificate", in: dictionary),
            hostPrivateKey: dataValue("HostPrivateKey", in: dictionary),
            rootCertificate: dataValue("RootCertificate", in: dictionary),
            rootPrivateKey: dataValue("RootPrivateKey", in: dictionary),
            escrowBag: dataValue("EscrowBag", in: dictionary),
            rawValues: dictionary.mapValues(DiagnosticValue.init)
        )
    }

    /// Names of fields missing for the built-in secure-session backend.
    ///
    /// `StartSession` itself only requires `HostID` and `SystemBUID`, but most
    /// devices then request secure traffic. The SwiftNIO SSL backend needs the
    /// device certificate for server trust plus the host certificate and
    /// private key for client identity.
    public var missingSecureSessionFields: [String] {
        [
            ("DeviceCertificate", deviceCertificate),
            ("HostCertificate", hostCertificate),
            ("HostPrivateKey", hostPrivateKey),
        ].compactMap { name, value in
            value == nil ? name : nil
        }
    }

    /// Whether this record contains material required by the built-in backend.
    ///
    /// This is a structural check only. It does not validate certificate chains
    /// or prove that the record still matches the connected device.
    public var hasSecureSessionMaterial: Bool {
        missingSecureSessionFields.isEmpty
    }
}

/// Sendable diagnostic wrapper for raw plist values.
///
/// Device services can return arbitrary plist values. Public value types in
/// this package are `Sendable`, so raw values are represented as stable
/// descriptions instead of exposing unconstrained `Any`.
public struct DiagnosticValue: Equatable, Sendable, CustomStringConvertible {
    /// String representation suitable for logs, CLI output, and tests.
    public let description: String

    /// Creates a diagnostic value from an already-normalized description.
    public init(description: String) {
        self.description = description
    }

    init(_ value: Any) {
        switch value {
        case let string as String:
            description = string
        case let data as Data:
            description = "<\(data.count) bytes>"
        case let number as NSNumber:
            description = number.stringValue
        default:
            description = String(describing: value)
        }
    }
}

/// Reads a required non-empty string from a pairing-record dictionary.
private func requiredString(_ key: String, in dictionary: [String: Any]) throws -> String {
    guard let value = dictionary[key] as? String else {
        throw RorkDeviceError.invalidPairingRecord("Missing \(key).")
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw RorkDeviceError.invalidPairingRecord("\(key) is empty.")
    }
    return trimmed
}

/// Reads binary pairing material from either plist data or legacy string form.
private func dataValue(_ key: String, in dictionary: [String: Any]) -> Data? {
    if let data = dictionary[key] as? Data, !data.isEmpty {
        return data
    }
    if let string = dictionary[key] as? String, !string.isEmpty {
        return Data(base64Encoded: string) ?? Data(string.utf8)
    }
    return nil
}
