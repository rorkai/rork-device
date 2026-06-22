import Foundation
import XCTest
@testable import RorkDevice

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RemotePairingIdentityTests: XCTestCase {
    func testGeneratesIdentityThatRoundTripsThroughPropertyList() throws {
        let identity = RemotePairingIdentity.generate()

        let restored = try RemotePairingIdentity(
            propertyList: identity.propertyList()
        )

        XCTAssertEqual(restored, identity)
        XCTAssertFalse(identity.identifier.isEmpty)
        XCTAssertEqual(identity.privateKeyData.count, 32)
        XCTAssertEqual(identity.publicKeyData.count, 32)
        XCTAssertEqual(identity.identityResolvingKey.count, 16)
    }

    func testGeneratedIdentitiesUseIndependentKeyMaterial() {
        let first = RemotePairingIdentity.generate()
        let second = RemotePairingIdentity.generate()

        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertNotEqual(first.privateKeyData, second.privateKeyData)
        XCTAssertNotEqual(
            first.identityResolvingKey,
            second.identityResolvingKey
        )
    }

    func testRejectsEmptyGeneratedIdentityIdentifier() {
        XCTAssertThrowsError(
            try RemotePairingIdentity.generate(identifier: " \n ")
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Remote pairing identity requires a nonempty identifier."
                )
            )
        }
    }

    func testWritesPrivateIdentityWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("identity.plist")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let identity = RemotePairingIdentity.generate()

        try identity.write(to: file)

        XCTAssertEqual(try RemotePairingIdentity(contentsOf: file), identity)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testCreatesTemporaryIdentityFileWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("identity.plist")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileManager = RecordingIdentityFileManager()

        try RemotePairingIdentity.generate().write(
            to: file,
            fileManager: fileManager
        )

        XCTAssertEqual(fileManager.createdFilePermissions, 0o600)
    }

    func testLoadOrCreatePersistsAndReusesOneIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("identity.plist")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let created = try RemotePairingIdentity.loadOrCreate(at: file)
        let restored = try RemotePairingIdentity.loadOrCreate(at: file)

        XCTAssertEqual(restored, created)
        XCTAssertEqual(try RemotePairingIdentity(contentsOf: file), created)
    }

    func testConcurrentLoadOrCreateReturnsTheIdentityThatWonCreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("identity.plist")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let identities = try await withThrowingTaskGroup(
            of: RemotePairingIdentity.self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    try RemotePairingIdentity.loadOrCreate(at: file)
                }
            }

            var identities: [RemotePairingIdentity] = []
            for try await identity in group {
                identities.append(identity)
            }
            return identities
        }

        let persisted = try RemotePairingIdentity(contentsOf: file)
        XCTAssertEqual(identities.count, 16)
        XCTAssertTrue(identities.allSatisfy { $0 == persisted })
    }

    func testParsesRemotePairingIdentity() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let plist: [String: Any] = [
            "identifier": "host-identifier",
            "privateKey": privateKey.rawRepresentation,
            "publicKey": privateKey.publicKey.rawRepresentation,
            "irk": Data(repeating: 0x5a, count: 16),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let identity = try RemotePairingIdentity(propertyList: data)

        XCTAssertEqual(identity.identifier, "host-identifier")
        XCTAssertEqual(identity.privateKeyData, privateKey.rawRepresentation)
    }

    func testRejectsMismatchedSigningKeys() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let plist: [String: Any] = [
            "identifier": "host-identifier",
            "privateKey": privateKey.rawRepresentation,
            "publicKey": otherKey.publicKey.rawRepresentation,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertThrowsError(try RemotePairingIdentity(propertyList: data)) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidPairingRecord("Remote pairing public key does not match the private key.")
            )
        }
    }

    func testRejectsInvalidIdentityResolvingKeyLength() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let plist: [String: Any] = [
            "identifier": "host-identifier",
            "privateKey": privateKey.rawRepresentation,
            "publicKey": privateKey.publicKey.rawRepresentation,
            "irk": Data(repeating: 0x5a, count: 15),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertThrowsError(try RemotePairingIdentity(propertyList: data)) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidPairingRecord("Remote pairing identity resolving key must contain 16 bytes.")
            )
        }
    }

    func testRejectsMissingIdentityResolvingKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let plist: [String: Any] = [
            "identifier": "host-identifier",
            "privateKey": privateKey.rawRepresentation,
            "publicKey": privateKey.publicKey.rawRepresentation,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        XCTAssertThrowsError(try RemotePairingIdentity(propertyList: data)) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidPairingRecord("Remote pairing identity is missing irk.")
            )
        }
    }

    func testStringRepresentationsDoNotExposePrivateKeyMaterial() {
        let signingKey = Curve25519.Signing.PrivateKey()
        let identity = RemotePairingIdentity(
            identifier: "host-identifier",
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x5a, count: 16)
        )

        XCTAssertEqual(
            String(describing: identity),
            "RemotePairingIdentity(identifier: \"host-identifier\")"
        )
        XCTAssertEqual(
            String(reflecting: identity),
            "RemotePairingIdentity(identifier: \"host-identifier\")"
        )
    }

    func testReflectionDoesNotExposePrivateKeyMaterial() {
        let signingKey = Curve25519.Signing.PrivateKey()
        let identity = RemotePairingIdentity(
            identifier: "host-identifier",
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x5a, count: 16)
        )

        XCTAssertEqual(
            Mirror(reflecting: identity).children.compactMap(\.label),
            ["identifier"]
        )
    }
}

/// Records the permissions supplied when an identity file is created.
///
/// The real file operation still runs so the test exercises the complete
/// atomic-write path while observing the security-sensitive creation mode.
private final class RecordingIdentityFileManager: FileManager, @unchecked Sendable {
    /// Protects the recorded creation mode from concurrent file operations.
    private let recordingLock = NSLock()

    /// POSIX mode supplied for the most recently created file.
    private var recordedFilePermissions: Int?

    /// POSIX mode supplied for the most recently created file.
    var createdFilePermissions: Int? {
        recordingLock.withLock { recordedFilePermissions }
    }

    /// Captures creation attributes before delegating to `FileManager`.
    override func createFile(
        atPath path: String,
        contents data: Data? = nil,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        recordingLock.withLock {
            recordedFilePermissions = (
                attr?[.posixPermissions] as? NSNumber
            )?.intValue
        }
        return super.createFile(
            atPath: path,
            contents: data,
            attributes: attr
        )
    }
}
