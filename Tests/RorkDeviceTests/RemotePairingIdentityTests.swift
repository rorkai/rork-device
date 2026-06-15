import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingIdentityTests: XCTestCase {
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

    func testStringRepresentationsDoNotExposePrivateKeyMaterial() {
        let identity = RemotePairingIdentity(
            identifier: "host-identifier",
            privateKeyData: Data(repeating: 0x5a, count: 32)
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
        let identity = RemotePairingIdentity(
            identifier: "host-identifier",
            privateKeyData: Data(repeating: 0x5a, count: 32)
        )

        XCTAssertEqual(
            Mirror(reflecting: identity).children.compactMap(\.label),
            ["identifier"]
        )
    }
}
