import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingProtocolTests: XCTestCase {
    func testPairVerifyCreatesAuthenticatedTCPListener() async throws {
        let signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1...32).map(UInt8.init))
        )
        let identity = RemotePairingIdentity(
            identifier: "test-host",
            privateKeyData: signingKey.rawRepresentation
        )
        let hostAgreementKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data((33...64).map(UInt8.init))
        )
        let deviceAgreementKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data((65...96).map(UInt8.init))
        )
        let sharedSecret = try hostAgreementKey.sharedSecretFromKeyAgreement(with: deviceAgreementKey.publicKey)
        let preSharedKey = sharedSecret.withUnsafeBytes { Data($0) }
        let serverCipher = mainCipher(secret: preSharedKey, info: "ServerEncrypt-main")
        let listenerResponse = try JSONSerialization.data(withJSONObject: [
            "response": [
                "_1": [
                    "createListener": [
                        "port": 54321,
                    ],
                ],
            ],
        ])
        let encryptedListenerResponse = try seal(listenerResponse, using: serverCipher, sequence: 0)

        var inbound = Data()
        inbound.append(try frame(plain: [
            "response": [
                "_1": [
                    "handshake": [
                        "_0": [:],
                    ],
                ],
            ],
        ]))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x02])),
            TLV8Field(type: 0x03, value: deviceAgreementKey.publicKey.rawRepresentation),
        ])))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x04])),
        ])))
        inbound.append(try RemotePairingFrameCodec.encode([
            "message": [
                "streamEncrypted": [
                    "_0": encryptedListenerResponse.base64EncodedString(),
                ],
            ],
        ]))
        let connection = FakeConnection(inbound: inbound)
        let client = RemotePairingProtocolClient(
            connection: connection,
            identity: identity,
            ephemeralKey: hostAgreementKey
        )

        let listener = try await client.createTunnelListener()

        XCTAssertEqual(listener.port, 54321)
        XCTAssertEqual(listener.preSharedKey, preSharedKey)
        XCTAssertEqual(connection.sent.count, 4)
        XCTAssertEqual(try sequenceNumber(in: connection.sent[0]), 0)
        XCTAssertEqual(try sequenceNumber(in: connection.sent[3]), 3)

        let signedPairingData = try pairingData(in: connection.sent[2])
        let signedTLV = try TLV8.decode(signedPairingData)
        let pairVerifyKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32
        )
        let plaintext = try open(
            signedTLV.value(for: 0x05),
            using: pairVerifyKey,
            nonce: Data([0, 0, 0, 0]) + Data("PV-Msg03".utf8)
        )
        let contents = try TLV8.decode(plaintext)
        XCTAssertEqual(contents.value(for: 0x01), Data(identity.identifier.utf8))

        var signedMessage = Data()
        signedMessage.append(hostAgreementKey.publicKey.rawRepresentation)
        signedMessage.append(Data(identity.identifier.utf8))
        signedMessage.append(deviceAgreementKey.publicKey.rawRepresentation)
        XCTAssertTrue(
            signingKey.publicKey.isValidSignature(contents.value(for: 0x0a), for: signedMessage)
        )
    }

    func testPairVerifyReportsDeviceRejection() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let identity = RemotePairingIdentity(
            identifier: "test-host",
            privateKeyData: signingKey.rawRepresentation
        )
        let hostAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let deviceAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        var inbound = Data()
        inbound.append(try frame(plain: [
            "response": [
                "_1": [
                    "handshake": [
                        "_0": [:],
                    ],
                ],
            ],
        ]))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x03, value: deviceAgreementKey.publicKey.rawRepresentation),
        ])))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x07, value: Data([0x04])),
        ])))
        let client = RemotePairingProtocolClient(
            connection: FakeConnection(inbound: inbound),
            identity: identity,
            ephemeralKey: hostAgreementKey
        )

        do {
            _ = try await client.createTunnelListener()
            XCTFail("Expected pair verification to fail.")
        } catch {
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("Remote pairing rejected this host identity with error 4.")
            )
        }
    }
}

private func frame(plain: [String: Any]) throws -> Data {
    try RemotePairingFrameCodec.encode([
        "message": [
            "plain": [
                "_0": plain,
            ],
        ],
    ])
}

private func pairingFrame(_ pairingData: Data) throws -> Data {
    try frame(plain: [
        "event": [
            "_0": [
                "pairingData": [
                    "_0": [
                        "data": pairingData.base64EncodedString(),
                    ],
                ],
            ],
        ],
    ])
}

private func sequenceNumber(in frame: Data) throws -> Int {
    let object = try decodeFrame(frame)
    return try XCTUnwrap(object["sequenceNumber"] as? Int)
}

private func pairingData(in frame: Data) throws -> Data {
    let object = try decodeFrame(frame)
    let message = try XCTUnwrap(object["message"] as? [String: Any])
    let plain = try XCTUnwrap(message["plain"] as? [String: Any])
    let payload = try XCTUnwrap(plain["_0"] as? [String: Any])
    let event = try XCTUnwrap(payload["event"] as? [String: Any])
    let eventPayload = try XCTUnwrap(event["_0"] as? [String: Any])
    let pairingData = try XCTUnwrap(eventPayload["pairingData"] as? [String: Any])
    let pairingPayload = try XCTUnwrap(pairingData["_0"] as? [String: Any])
    let base64 = try XCTUnwrap(pairingPayload["data"] as? String)
    return try XCTUnwrap(Data(base64Encoded: base64))
}

private func decodeFrame(_ frame: Data) throws -> [String: Any] {
    let payloadOffset = RemotePairingFrameCodec.magic.count + 2
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: frame.dropFirst(payloadOffset)) as? [String: Any]
    )
}

private func mainCipher(secret: Data, info: String) -> SymmetricKey {
    HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(),
        info: Data(info.utf8),
        outputByteCount: 32
    )
}

private func seal(_ plaintext: Data, using key: SymmetricKey, sequence: UInt64) throws -> Data {
    var nonceData = Data()
    nonceData.appendLittleEndian(sequence)
    nonceData.append(Data(repeating: 0, count: 4))
    let sealed = try ChaChaPoly.seal(
        plaintext,
        using: key,
        nonce: try ChaChaPoly.Nonce(data: nonceData)
    )
    return sealed.ciphertext + sealed.tag
}

private func open(_ ciphertextAndTag: Data, using key: SymmetricKey, nonce: Data) throws -> Data {
    let tagOffset = ciphertextAndTag.count - 16
    let box = try ChaChaPoly.SealedBox(
        nonce: try ChaChaPoly.Nonce(data: nonce),
        ciphertext: ciphertextAndTag.prefix(tagOffset),
        tag: ciphertextAndTag.suffix(16)
    )
    return try ChaChaPoly.open(box, using: key)
}
