import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingProtocolTests: XCTestCase {
    func testTrustEstablishmentReturnsWhenTheIdentityAlreadyVerifies() async throws {
        let scenario = try pairingScenario()

        try await scenario.client.establishTrustIfNeeded()

        XCTAssertEqual(scenario.connection.sent.count, 3)
    }

    func testTrustEstablishmentPairsAnUnknownIdentity() async throws {
        var didEnrollIdentity = false
        let signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1...32).map(UInt8.init))
        )
        let identity = RemotePairingIdentity(
            identifier: "test-host",
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x7a, count: 16)
        )
        let hostAgreementKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data((33...64).map(UInt8.init))
        )
        let deviceAgreementKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data((65...96).map(UInt8.init))
        )
        let sessionKey = try protocolData(
            hexadecimal:
                "e0071ef3951ca250799e6fc77df75a8c62a5b4bfc9424743fd699fef2ddc4780"
                + "bd303b0188fc985d79c45aa350705c2883caca77e18710d960e9f6dfe9c44278"
        )
        let setupEncryptionKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8),
            outputByteCount: 32
        )
        let encryptedDeviceInfo = try seal(
            Data([0x01]),
            using: setupEncryptionKey,
            nonce: Data([0, 0, 0, 0]) + Data("PS-Msg06".utf8)
        )
        let encryptedUnlockResponse = try seal(
            JSONSerialization.data(withJSONObject: [
                "response": [
                    "_1": [
                        "createRemoteUnlockKey": [:],
                    ],
                ],
            ]),
            using: mainCipher(
                secret: sessionKey,
                info: "ServerEncrypt-main"
            ),
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
            TLV8Field(type: 0x06, value: Data([0x02])),
            TLV8Field(
                type: 0x03,
                value: deviceAgreementKey.publicKey.rawRepresentation
            ),
        ])))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x07, value: Data([0x04])),
        ])))
        inbound.append(try frame(plain: [:]))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x02])),
            TLV8Field(
                type: 0x03,
                value: try protocolData(hexadecimal: """
                    7e6059797918050391cb91311f49917a79581a54f73e39ac88268e4429af6c89
                    aa16693cef2afa53246006db729bc89423aaef8a7598608c50183a80a8bdc651
                    4576d1005125b1fcac3fcbe4ba83e24c96521b390d8e4e5c3d853995df7a69f4
                    e1cf9e39aa213a8b6da6c2f024bae6174124f5807c37d127c14880701fec3898
                    cd652559fa7aaaae76e60e30c21d4ec4d947b426e88e31dea1bf9888aefc2494
                    3c485f71fefd530620c1ba6ae76557130ef8c2fdf134ffb3838bead0dee14a65
                    bcaa2442566278b5542c9c0e7b5737f94331e6dcd6da91607ea3b71863b86d3
                    f04a73dac1d2aa3dfe29c2c273cff7a953355fb3ea59e450d8f909ae098c3926
                    58a45855367136624912eca0bf9022dcb4ee404cc77bbc99c235e020b1a07d017
                    ba94e69c82e3ff78c2474cf2fa9239697f99ea511765516987e3256a9d510418
                    6aba6f210ff99bac02e36a8018e9999b042b70a05ee1b22e92291532c34bc043
                    487486e2c855373c963fe354389ed981c6d3c072af4a8739b8908f704e45b724
                    """)
            ),
            TLV8Field(
                type: 0x02,
                value: try protocolData(
                    hexadecimal: "000102030405060708090a0b0c0d0e0f"
                )
            ),
        ])))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x04])),
            TLV8Field(
                type: 0x04,
                value: try protocolData(
                    hexadecimal:
                        "82aea05a663dfe562e4b6d7755fb4bcff5fd6a6f94fb540c82971cf8246ac081"
                        + "1dff3588bcdbe24d1e2dee9f265ab9ab971e62d5d08091676522a4e0900ab51a"
                )
            ),
        ])))
        inbound.append(try pairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x06])),
            TLV8Field(type: 0x05, value: encryptedDeviceInfo),
        ])))
        inbound.append(try RemotePairingFrameCodec.encode([
            "message": [
                "streamEncrypted": [
                    "_0": encryptedUnlockResponse.base64EncodedString(),
                ],
            ],
        ]))

        let connection = FakeConnection(inbound: inbound)
        let client = RemotePairingProtocolClient(
            connection: connection,
            identity: identity,
            ephemeralKey: hostAgreementKey,
            makeSRPClient: {
                try RemotePairingSRPClient(
                    privateKey: Data((1...32).map(UInt8.init))
                )
            }
        )

        try await client.establishTrustIfNeeded(
            willEstablishTrust: {},
            didEnrollIdentity: {
                didEnrollIdentity = true
            }
        )

        XCTAssertTrue(didEnrollIdentity)
        XCTAssertEqual(connection.sent.count, 8)
        let setupStart = try pairingEnvelope(in: connection.sent[4])
        XCTAssertEqual(setupStart.kind, "setupManualPairing")
        XCTAssertTrue(setupStart.startsNewSession)
        XCTAssertEqual(
            try TLV8.decode(setupStart.data).value(for: 0x06),
            Data([0x01])
        )
        let setupProof = try pairingEnvelope(in: connection.sent[5])
        XCTAssertEqual(
            try TLV8.decode(setupProof.data).value(for: 0x06),
            Data([0x03])
        )
        let setupIdentity = try pairingEnvelope(in: connection.sent[6])
        XCTAssertEqual(
            try TLV8.decode(setupIdentity.data).value(for: 0x06),
            Data([0x05])
        )

        let interruptedConnection = FakeConnection(
            inbound: inbound,
            receiveFailureAfterSendCount: 8
        )
        let interruptedClient = RemotePairingProtocolClient(
            connection: interruptedConnection,
            identity: identity,
            ephemeralKey: hostAgreementKey,
            makeSRPClient: {
                try RemotePairingSRPClient(
                    privateKey: Data((1...32).map(UInt8.init))
                )
            }
        )
        var didEnrollBeforeInterruption = false

        await XCTAssertThrowsErrorAsync({
            try await interruptedClient.establishTrustIfNeeded(
                willEstablishTrust: {},
                didEnrollIdentity: {
                    didEnrollBeforeInterruption = true
                }
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport("Injected receive failure.")
            )
        }

        XCTAssertTrue(didEnrollBeforeInterruption)
    }

    func testTrustEstablishmentStartsPairSetupAfterAuthenticationRejection() async throws {
        let scenario = try rejectedVerificationScenario(errorCode: 0x02)

        await XCTAssertThrowsErrorAsync({
            try await scenario.client.establishTrustIfNeeded()
        }) { _ in }

        XCTAssertEqual(scenario.connection.sent.count, 5)
        let setupStart = try pairingEnvelope(in: scenario.connection.sent[4])
        XCTAssertEqual(setupStart.kind, "setupManualPairing")
        XCTAssertTrue(setupStart.startsNewSession)
    }

    func testTrustEstablishmentPreservesBackoffRejection() async throws {
        let scenario = try rejectedVerificationScenario(
            errorCode: 0x03,
            retryDelay: Data([30])
        )

        await XCTAssertThrowsErrorAsync({
            try await scenario.client.establishTrustIfNeeded()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remotePairing(.backoff(retryDelay: .seconds(30)))
            )
        }

        XCTAssertEqual(scenario.connection.sent.count, 4)
    }

    func testTrustEstablishmentPreservesMaximumPeersRejection() async throws {
        let scenario = try rejectedVerificationScenario(errorCode: 0x05)

        await XCTAssertThrowsErrorAsync({
            try await scenario.client.establishTrustIfNeeded()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remotePairing(.maximumPeers)
            )
        }

        XCTAssertEqual(scenario.connection.sent.count, 4)
    }

    func testTrustEstablishmentPreservesMaximumAttemptsRejection() async throws {
        let scenario = try rejectedVerificationScenario(errorCode: 0x06)

        await XCTAssertThrowsErrorAsync({
            try await scenario.client.establishTrustIfNeeded()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remotePairing(.maximumAttempts)
            )
        }

        XCTAssertEqual(scenario.connection.sent.count, 4)
    }

    func testTrustEstablishmentPreservesUnrecognizedRejection() async throws {
        let scenario = try rejectedVerificationScenario(errorCode: 0x7f)

        await XCTAssertThrowsErrorAsync({
            try await scenario.client.establishTrustIfNeeded()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remotePairing(.unrecognized(code: 0x7f))
            )
        }

        XCTAssertEqual(scenario.connection.sent.count, 4)
    }

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
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x7a, count: 16)
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
                .remotePairing(.unknownPeer)
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
        privateKey: signingKey,
        identityResolvingKey: Data(repeating: 0x7a, count: 16)
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

/// Creates a pair-verification exchange that ends with a device rejection.
private func rejectedVerificationScenario(
    errorCode: UInt8,
    retryDelay: Data = Data()
) throws -> (client: RemotePairingProtocolClient, connection: FakeConnection) {
    let signingKey = Curve25519.Signing.PrivateKey()
    let identity = RemotePairingIdentity(
        identifier: "test-host",
        privateKey: signingKey,
        identityResolvingKey: Data(repeating: 0x7a, count: 16)
    )
    let deviceAgreementKey = Curve25519.KeyAgreement.PrivateKey()

    var rejectionFields = [
        TLV8Field(type: 0x07, value: Data([errorCode])),
    ]
    if !retryDelay.isEmpty {
        rejectionFields.append(
            TLV8Field(type: 0x08, value: retryDelay)
        )
    }

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
        TLV8Field(
            type: 0x03,
            value: deviceAgreementKey.publicKey.rawRepresentation
        ),
    ])))
    inbound.append(try pairingFrame(TLV8.encode(rejectionFields)))

    let connection = FakeConnection(inbound: inbound)
    return (
        RemotePairingProtocolClient(
            connection: connection,
            identity: identity
        ),
        connection
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
    try pairingEnvelope(in: frame).data
}

private func pairingEnvelope(
    in frame: Data
) throws -> (data: Data, kind: String?, startsNewSession: Bool) {
    let object = try decodeFrame(frame)
    let message = try XCTUnwrap(object["message"] as? [String: Any])
    let plain = try XCTUnwrap(message["plain"] as? [String: Any])
    let payload = try XCTUnwrap(plain["_0"] as? [String: Any])
    let event = try XCTUnwrap(payload["event"] as? [String: Any])
    let eventPayload = try XCTUnwrap(event["_0"] as? [String: Any])
    let pairingData = try XCTUnwrap(eventPayload["pairingData"] as? [String: Any])
    let pairingPayload = try XCTUnwrap(pairingData["_0"] as? [String: Any])
    let base64 = try XCTUnwrap(pairingPayload["data"] as? String)
    return (
        try XCTUnwrap(Data(base64Encoded: base64)),
        pairingPayload["kind"] as? String,
        pairingPayload["startNewSession"] as? Bool ?? false
    )
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
    return try seal(plaintext, using: key, nonce: nonceData)
}

private func seal(
    _ plaintext: Data,
    using key: SymmetricKey,
    nonce: Data
) throws -> Data {
    let sealed = try ChaChaPoly.seal(
        plaintext,
        using: key,
        nonce: try ChaChaPoly.Nonce(data: nonce)
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

private func protocolData(hexadecimal value: String) throws -> Data {
    let hexadecimal = value.filter { !$0.isWhitespace }
    guard hexadecimal.count.isMultiple(of: 2) else {
        throw RorkDeviceError.invalidInput(
            "Hexadecimal fixture has an odd number of digits."
        )
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(hexadecimal.count / 2)
    var index = hexadecimal.startIndex
    while index < hexadecimal.endIndex {
        let nextIndex = hexadecimal.index(index, offsetBy: 2)
        guard let byte = UInt8(hexadecimal[index..<nextIndex], radix: 16) else {
            throw RorkDeviceError.invalidInput(
                "Hexadecimal fixture contains a non-hexadecimal digit."
            )
        }
        bytes.append(byte)
        index = nextIndex
    }
    return Data(bytes)
}
