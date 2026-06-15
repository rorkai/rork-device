import CryptoKit
import Foundation

/// Long-lived host identity used to authenticate a remote-pairing session.
///
/// The identity contains an Ed25519 signing key pair and stable identifier
/// previously accepted by the target device. It is distinct from a Lockdown
/// pairing record: remote pairing uses this material during pair verification,
/// before negotiating the TLS pre-shared key that protects the packet tunnel.
///
/// Treat instances as sensitive credentials. In particular, do not log or
/// serialize the instance outside storage already intended for pairing material.
public struct RemotePairingIdentity:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    /// Stable host identifier presented and signed during pair verification.
    ///
    /// The target device must already recognize this identifier and the
    /// corresponding public key. Changing it creates a different host identity,
    /// even when the key material is otherwise unchanged.
    public let identifier: String

    /// Raw 32-byte Ed25519 private key used internally for pair verification.
    let privateKeyData: Data

    /// A diagnostic representation that identifies the credential without its key.
    public var description: String {
        "RemotePairingIdentity(identifier: \(String(reflecting: identifier)))"
    }

    /// A debug representation that preserves the credential's redaction boundary.
    public var debugDescription: String {
        description
    }

    /// A mirror that exposes the identifier while omitting private key material.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["identifier": identifier],
            displayStyle: .struct
        )
    }

    /// Creates an identity from already validated fields.
    ///
    /// This initializer remains internal so tests and package components can
    /// construct fixtures without exposing credential bytes to API consumers.
    init(
        identifier: String,
        privateKeyData: Data
    ) {
        self.identifier = identifier
        self.privateKeyData = privateKeyData
    }

    /// Creates an identity from a binary or XML property list.
    ///
    /// Validation checks all required fields, key lengths, and that the public
    /// key is derived from the supplied private key. Invalid material is rejected
    /// before any network request is attempted.
    ///
    /// - Parameter data: Serialized remote-pairing identity property list.
    /// - Throws: `RorkDeviceError.invalidPairingRecord` when the property list or
    ///   cryptographic key material is incomplete or inconsistent.
    public init(propertyList data: Data) throws {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw RorkDeviceError.invalidPairingRecord("Remote pairing identity is not a valid property list.")
        }
        guard let dictionary = object as? [String: Any] else {
            throw RorkDeviceError.invalidPairingRecord("Remote pairing identity is not a property list dictionary.")
        }

        let identifier = try requiredString("identifier", in: dictionary)
        let privateKeyData = try requiredData("privateKey", byteCount: 32, in: dictionary)
        let publicKeyData = try requiredData("publicKey", byteCount: 32, in: dictionary)
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        } catch {
            throw RorkDeviceError.invalidPairingRecord("Remote pairing private key is invalid.")
        }
        guard privateKey.publicKey.rawRepresentation == publicKeyData else {
            throw RorkDeviceError.invalidPairingRecord("Remote pairing public key does not match the private key.")
        }

        if let value = dictionary["irk"] {
            guard let data = value as? Data, data.count == 16 else {
                throw RorkDeviceError.invalidPairingRecord(
                    "Remote pairing identity resolving key must contain 16 bytes."
                )
            }
        }

        self.init(
            identifier: identifier,
            privateKeyData: privateKeyData
        )
    }

    /// Creates an identity from a property-list file.
    ///
    /// - Parameter url: File containing a binary or XML identity property list.
    /// - Throws: File-loading errors or the validation errors documented by
    ///   `init(propertyList:)`.
    public init(contentsOf url: URL) throws {
        try self.init(propertyList: Data(contentsOf: url))
    }
}

/// Reads a required, nonempty string from an identity property list.
private func requiredString(_ key: String, in dictionary: [String: Any]) throws -> String {
    guard let value = dictionary[key] as? String else {
        throw RorkDeviceError.invalidPairingRecord("Remote pairing identity is missing \(key).")
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw RorkDeviceError.invalidPairingRecord("Remote pairing identity has an empty \(key).")
    }
    return trimmed
}

/// Reads fixed-length binary key material from an identity property list.
private func requiredData(
    _ key: String,
    byteCount: Int,
    in dictionary: [String: Any]
) throws -> Data {
    guard let value = dictionary[key] as? Data else {
        throw RorkDeviceError.invalidPairingRecord("Remote pairing identity is missing \(key).")
    }
    guard value.count == byteCount else {
        throw RorkDeviceError.invalidPairingRecord(
            "Remote pairing identity \(key) must contain \(byteCount) bytes."
        )
    }
    return value
}
