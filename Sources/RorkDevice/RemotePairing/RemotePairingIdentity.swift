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

    /// Raw 32-byte Ed25519 public key registered with the device.
    let publicKeyData: Data

    /// Stable 16-byte resolving key included in manual pair-setup metadata.
    let identityResolvingKey: Data

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

    /// Generates a new host identity with a random identifier and key material.
    ///
    /// The identifier is an uppercase UUID, matching the stable identifier form
    /// used by Apple's remote-pairing records. The Ed25519 signing key and
    /// 16-byte identity resolving key are generated independently with the
    /// platform's cryptographically secure random-number generator.
    ///
    /// - Returns: A complete identity ready to persist or enroll with a device.
    public static func generate() -> RemotePairingIdentity {
        RemotePairingIdentity(
            identifier: UUID().uuidString.uppercased(),
            privateKey: Curve25519.Signing.PrivateKey(),
            identityResolvingKey: randomIdentityResolvingKey()
        )
    }

    /// Generates a new host identity with a caller-supplied stable identifier.
    ///
    /// Use this overload only when another system owns the host identifier. New
    /// applications should normally call `generate()` and persist the returned
    /// identity unchanged for future sessions.
    ///
    /// - Parameter identifier: Nonempty identifier presented during pairing.
    /// - Returns: A complete identity with newly generated secret material.
    /// - Throws: `RorkDeviceError.invalidInput` when `identifier` contains only
    ///   whitespace.
    public static func generate(
        identifier: String
    ) throws -> RemotePairingIdentity {
        let identifier = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing identity requires a nonempty identifier."
            )
        }
        return RemotePairingIdentity(
            identifier: identifier,
            privateKey: Curve25519.Signing.PrivateKey(),
            identityResolvingKey: randomIdentityResolvingKey()
        )
    }

    /// Creates an identity from validated cryptographic material.
    ///
    /// Accepting CryptoKit's signing-key type keeps malformed raw key bytes out
    /// of the protocol layer. The resolving key is an internal protocol field
    /// whose fixed width is enforced at the construction boundary.
    ///
    /// - Parameters:
    ///   - identifier: Stable identifier presented to the device.
    ///   - privateKey: Ed25519 key used to sign pair-verification transcripts.
    ///   - identityResolvingKey: Sixteen-byte key sent during manual pair setup.
    /// - Precondition: `identityResolvingKey` contains exactly 16 bytes.
    init(
        identifier: String,
        privateKey: Curve25519.Signing.PrivateKey,
        identityResolvingKey: Data
    ) {
        precondition(
            identityResolvingKey.count == 16,
            "Remote pairing identity resolving key must contain 16 bytes."
        )
        self.identifier = identifier
        privateKeyData = privateKey.rawRepresentation
        publicKeyData = privateKey.publicKey.rawRepresentation
        self.identityResolvingKey = identityResolvingKey
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

        let identityResolvingKey = try requiredIdentityResolvingKey(
            in: dictionary
        )

        self.init(
            identifier: identifier,
            privateKey: privateKey,
            identityResolvingKey: identityResolvingKey
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

    /// Loads an existing identity or creates and persists a new one.
    ///
    /// The destination's parent directory must already exist. Once an identity
    /// has been created, subsequent calls return the same credential so devices
    /// continue to recognize the host. If another process wins the initial
    /// creation race, this method loads that process's complete identity rather
    /// than replacing it.
    ///
    /// - Parameter url: Stable property-list location for the host identity.
    /// - Returns: The validated existing identity or the newly persisted one.
    /// - Throws: File-system, serialization, or identity-validation errors.
    public static func loadOrCreate(
        at url: URL
    ) throws -> RemotePairingIdentity {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return try RemotePairingIdentity(contentsOf: url)
        }

        let identity = RemotePairingIdentity.generate()
        let candidateURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).candidate"
            )
        defer {
            try? fileManager.removeItem(at: candidateURL)
        }

        do {
            try identity.write(to: candidateURL)
            try fileManager.linkItem(at: candidateURL, to: url)
            return identity
        } catch {
            guard fileManager.fileExists(atPath: url.path) else {
                throw error
            }
            return try RemotePairingIdentity(contentsOf: url)
        }
    }

    /// Serializes the complete identity as an Apple property list.
    ///
    /// The output includes private key material and must be handled as a
    /// credential. Binary property lists are used by default because they match
    /// the on-disk remote-pairing format while remaining readable by
    /// `init(propertyList:)`.
    ///
    /// - Parameter format: Property-list encoding to produce.
    /// - Returns: Serialized identity bytes.
    /// - Throws: A Foundation property-list serialization error.
    public func propertyList(
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "identifier": identifier,
                "privateKey": privateKeyData,
                "publicKey": publicKeyData,
                "irk": identityResolvingKey,
            ],
            format: format,
            options: 0
        )
    }

    /// Persists the complete identity with owner-only file permissions.
    ///
    /// The destination's parent directory must already exist. Serialization is
    /// written to a sibling temporary file, restricted to mode `0600`, and then
    /// moved into place so callers never observe a partially written identity.
    ///
    /// - Parameters:
    ///   - url: Destination property-list file.
    ///   - format: Property-list encoding to write.
    /// - Throws: Serialization or file-system errors. A failed write removes its
    ///   temporary file and leaves the previous destination untouched.
    public func write(
        to url: URL,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws {
        let data = try propertyList(format: format)
        let fileManager = FileManager.default
        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
            )

        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// Generates the fixed-width resolving key included in pair-setup metadata.
private func randomIdentityResolvingKey() -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data(
        (0..<16).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
    )
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

/// Reads the fixed-width resolving key required for manual pair setup.
private func requiredIdentityResolvingKey(
    in dictionary: [String: Any]
) throws -> Data {
    guard let value = dictionary["irk"] else {
        throw RorkDeviceError.invalidPairingRecord(
            "Remote pairing identity is missing irk."
        )
    }
    guard let data = value as? Data, data.count == 16 else {
        throw RorkDeviceError.invalidPairingRecord(
            "Remote pairing identity resolving key must contain 16 bytes."
        )
    }
    return data
}
