import Foundation

/// Lockdown pairing record used to authenticate with a device.
///
/// A pairing record is the trust material created when a host pairs with an iOS
/// device. `rork-device` can create one through `DeviceClient`, load it from a
/// property list, or retrieve the copy stored by local `usbmuxd`, then use it
/// for authenticated Lockdown sessions.
///
/// The parser accepts XML and binary property lists. Unknown plist fields are
/// retained when the record is serialized again, which lets callers export the
/// daemon's complete pairing material without depending on a fixed field list.
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

    /// Wi-Fi hardware address recorded during the original Lockdown pairing.
    public let wiFiMACAddress: String?

    /// Raw plist values converted to stable diagnostic descriptions.
    public let rawValues: [String: DiagnosticValue]

    /// Normalized binary plist retaining values not modeled as typed fields.
    private let serializedPropertyList: Data

    /// Compares the semantic pairing-record fields rather than plist bytes.
    ///
    /// Binary property-list encoders may emit equivalent dictionaries with a
    /// different key order. The normalized bytes are retained for lossless
    /// serialization but are not part of record identity.
    public static func == (
        lhs: PairingRecord,
        rhs: PairingRecord
    ) -> Bool {
        lhs.udid == rhs.udid
            && lhs.hostID == rhs.hostID
            && lhs.systemBUID == rhs.systemBUID
            && lhs.deviceCertificate == rhs.deviceCertificate
            && lhs.hostCertificate == rhs.hostCertificate
            && lhs.hostPrivateKey == rhs.hostPrivateKey
            && lhs.rootCertificate == rhs.rootCertificate
            && lhs.rootPrivateKey == rhs.rootPrivateKey
            && lhs.escrowBag == rhs.escrowBag
            && lhs.wiFiMACAddress == rhs.wiFiMACAddress
            && lhs.rawValues == rhs.rawValues
    }

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

        let normalizedData = try PropertyListCodec.encode(
            dictionary,
            format: .binary
        )
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
            wiFiMACAddress: optionalNonemptyString(
                "WiFiMACAddress",
                in: dictionary
            ),
            rawValues: dictionary.mapValues(DiagnosticValue.init),
            serializedPropertyList: normalizedData
        )
    }

    /// Serializes the complete pairing record as a property list.
    ///
    /// Values not represented by typed properties are preserved from the
    /// original record. This is useful when exporting pairing material to
    /// another process or saving it back through usbmux without narrowing the
    /// schema to fields known by this package version.
    ///
    /// - Parameter format: XML or binary property-list encoding.
    /// - Returns: Encoded pairing-record data.
    public func propertyListData(
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        let values = try PropertyListCodec.decode(serializedPropertyList)
        return try PropertyListCodec.encode(values, format: format)
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

    /// Public certificate material included in a Lockdown `Pair` request.
    ///
    /// Private keys and an existing escrow bag must never be sent to the
    /// device. They remain host-only fields in the saved pairing record.
    func pairingRequestValues() throws -> [String: Any] {
        guard let deviceCertificate else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing DeviceCertificate."
            )
        }
        guard let hostCertificate else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing HostCertificate."
            )
        }
        guard let rootCertificate else {
            throw RorkDeviceError.invalidPairingRecord(
                "Missing RootCertificate."
            )
        }
        return [
            "DeviceCertificate": deviceCertificate,
            "HostCertificate": hostCertificate,
            "RootCertificate": rootCertificate,
            "HostID": hostID,
            "SystemBUID": systemBUID,
        ]
    }

    /// Returns the accepted host record after Lockdown issues escrow material.
    ///
    /// Pairing identity, certificates, private keys, and unknown plist fields
    /// remain byte-for-byte equivalent at the property-list value level. Only
    /// `EscrowBag` is replaced.
    func addingEscrowBag(_ escrowBag: Data) throws -> PairingRecord {
        guard !escrowBag.isEmpty else {
            throw RorkDeviceError.invalidPairingRecord(
                "EscrowBag is empty."
            )
        }
        guard var values = try PropertyListCodec.decode(
            serializedPropertyList
        ) as? [String: Any] else {
            throw RorkDeviceError.invalidPairingRecord(
                "Expected plist dictionary."
            )
        }
        values["EscrowBag"] = escrowBag
        return try PairingRecord.parse(
            PropertyListCodec.encode(values, format: .binary)
        )
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

/// Reads an optional string while treating an empty value as absent.
private func optionalNonemptyString(
    _ key: String,
    in dictionary: [String: Any]
) -> String? {
    guard let value = dictionary[key] as? String else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
