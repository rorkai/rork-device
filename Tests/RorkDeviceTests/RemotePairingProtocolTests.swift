import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingProtocolTests: XCTestCase {
    func testPairVerifyCreatesAuthenticatedTCPListener() async throws {
        let scenario = try pairingScenario()

        let listener = try await scenario.client.createTunnelListener()

        XCTAssertEqual(listener.port, 54321)
        XCTAssertEqual(listener.preSharedKey, scenario.preSharedKey)
        XCTAssertEqual(scenario.connection.sent.count, 4)
        XCTAssertEqual(try sequenceNumber(in: scenario.connection.sent[0]), 0)
        XCTAssertEqual(try sequenceNumber(in: scenario.connection.sent[3]), 3)

        let signedPairingData = try pairingData(in: scenario.connection.sent[2])
        let signedTLV = try TLV8.decode(signedPairingData)
        let pairVerifyKey = scenario.sharedSecret.hkdfDerivedSymmetricKey(
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
        XCTAssertEqual(
            contents.value(for: 0x01),
            Data(scenario.identity.identifier.utf8)
        )

        var signedMessage = Data()
        signedMessage.append(scenario.hostAgreementKey.publicKey.rawRepresentation)
        signedMessage.append(Data(scenario.identity.identifier.utf8))
        signedMessage.append(
            scenario.deviceAgreementKey.publicKey.rawRepresentation
        )
        XCTAssertTrue(
            scenario.signingKey.publicKey.isValidSignature(
                contents.value(for: 0x0a),
                for: signedMessage
            )
        )
    }

    func testPairVerifyRejectsUnexpectedInitialState() async throws {
        let scenario = try pairingScenario(initialState: 0x03)

        await XCTAssertThrowsErrorAsync({
            _ = try await scenario.client.createTunnelListener()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote pairing response has an unexpected pair-verification state."
                )
            )
        }
    }

    func testPairVerifyRejectsUnexpectedFinalState() async throws {
        let scenario = try pairingScenario(finalState: 0x05)

        await XCTAssertThrowsErrorAsync({
            _ = try await scenario.client.createTunnelListener()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote pairing response has an unexpected pair-verification state."
                )
            )
        }
    }

    func testListenerRejectsBooleanPort() async throws {
        let scenario = try pairingScenario(listenerPort: true)

        await XCTAssertThrowsErrorAsync({
            _ = try await scenario.client.createTunnelListener()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Remote pairing listener response is missing a valid port."
                )
            )
        }
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
            TLV8Field(type: 0x06, value: Data([0x02])),
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

/// Deterministic cryptographic state and transport fixtures for pair verification.
private struct PairingScenario {
    /// Protocol client under test.
    let client: RemotePairingProtocolClient

    /// In-memory connection containing the simulated device responses.
    let connection: FakeConnection

    /// Long-lived host identity presented to the simulated device.
    let identity: RemotePairingIdentity

    /// Host signing key corresponding to `identity`.
    let signingKey: Curve25519.Signing.PrivateKey

    /// Ephemeral host key used for pair-verification key agreement.
    let hostAgreementKey: Curve25519.KeyAgreement.PrivateKey

    /// Ephemeral device key embedded in the simulated response.
    let deviceAgreementKey: Curve25519.KeyAgreement.PrivateKey

    /// Shared secret derived from the deterministic agreement keys.
    let sharedSecret: SharedSecret

    /// Raw shared-secret bytes expected in the tunnel-listener result.
    let preSharedKey: Data
}

/// Creates a deterministic pair-verification exchange for protocol tests.
private func pairingScenario(
    initialState: UInt8 = 0x02,
    finalState: UInt8 = 0x04,
    listenerPort: Any = 54_321
) throws -> PairingScenario {
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
    let sharedSecret = try hostAgreementKey.sharedSecretFromKeyAgreement(
        with: deviceAgreementKey.publicKey
    )
    let preSharedKey = sharedSecret.withUnsafeBytes { Data($0) }
    let serverCipher = mainCipher(
        secret: preSharedKey,
        info: "ServerEncrypt-main"
    )
    let listenerResponse = try JSONSerialization.data(withJSONObject: [
        "response": [
            "_1": [
                "createListener": [
                    "port": listenerPort,
                ],
            ],
        ],
    ])
    let encryptedListenerResponse = try seal(
        listenerResponse,
        using: serverCipher,
        sequence: 0
    )

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
        TLV8Field(type: 0x06, value: Data([initialState])),
        TLV8Field(
            type: 0x03,
            value: deviceAgreementKey.publicKey.rawRepresentation
        ),
    ])))
    inbound.append(try pairingFrame(TLV8.encode([
        TLV8Field(type: 0x06, value: Data([finalState])),
    ])))
    inbound.append(try RemotePairingFrameCodec.encode([
        "message": [
            "streamEncrypted": [
                "_0": encryptedListenerResponse.base64EncodedString(),
            ],
        ],
    ]))
    let connection = FakeConnection(inbound: inbound)

    return PairingScenario(
        client: RemotePairingProtocolClient(
            connection: connection,
            identity: identity,
            ephemeralKey: hostAgreementKey
        ),
        connection: connection,
        identity: identity,
        signingKey: signingKey,
        hostAgreementKey: hostAgreementKey,
        deviceAgreementKey: deviceAgreementKey,
        sharedSecret: sharedSecret,
        preSharedKey: preSharedKey
    )
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
    guard ciphertextAndTag.count >= 16 else {
        throw RorkDeviceError.protocolViolation(
            "Encrypted pairing payload is missing an authentication tag."
        )
    }
    let tagOffset = ciphertextAndTag.count - 16
    let box = try ChaChaPoly.SealedBox(
        nonce: try ChaChaPoly.Nonce(data: nonce),
        ciphertext: ciphertextAndTag.prefix(tagOffset),
        tag: ciphertextAndTag.suffix(16)
    )
    return try ChaChaPoly.open(box, using: key)
}
