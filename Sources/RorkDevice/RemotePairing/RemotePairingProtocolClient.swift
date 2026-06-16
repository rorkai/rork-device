import CryptoKit
import Foundation

/// Device-side listener prepared to accept the protected packet stream.
struct RemotePairingTunnelListener: Equatable {
    /// TCP port allocated by the device for the next tunnel connection.
    let port: UInt16

    /// Shared secret used as the TLS 1.2 pre-shared key for that connection.
    let preSharedKey: Data
}

/// Session keys derived after the device accepts the host identity.
private struct VerifiedRemotePairingKeys {
    /// Raw shared secret reused as the tunnel listener's TLS pre-shared key.
    let preSharedKey: Data

    /// ChaCha20-Poly1305 key for messages sent from the host to the device.
    let hostToDeviceCipher: SymmetricKey

    /// ChaCha20-Poly1305 key for messages sent from the device to the host.
    let deviceToHostCipher: SymmetricKey
}

/// Drives pair verification and asks the device to allocate a tunnel listener.
final class RemotePairingProtocolClient {
    /// Outer transport used to exchange remote-pairing messages.
    private let channel: any RemotePairingControlChannel

    /// Previously trusted host identity presented during pair verification.
    private let identity: RemotePairingIdentity

    /// Per-session X25519 key used to establish the shared secret.
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    /// Creates the SRP client only when pair verification rejects the identity.
    private let makeSRPClient: () throws -> RemotePairingSRPClient

    /// Sequence number used to derive nonces for encrypted stream messages.
    private var encryptionSequenceNumber: UInt64 = 0

    /// Creates a protocol driver over an established control stream.
    init(
        connection: DeviceConnection,
        identity: RemotePairingIdentity,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(),
        makeSRPClient: @escaping () throws -> RemotePairingSRPClient = {
            try RemotePairingSRPClient()
        }
    ) {
        channel = RemotePairingFramedControlChannel(
            connection: connection
        )
        self.identity = identity
        self.ephemeralKey = ephemeralKey
        self.makeSRPClient = makeSRPClient
    }

    /// Creates a protocol driver over a transport-specific control channel.
    init(
        channel: any RemotePairingControlChannel,
        identity: RemotePairingIdentity,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(),
        makeSRPClient: @escaping () throws -> RemotePairingSRPClient = {
            try RemotePairingSRPClient()
        }
    ) {
        self.channel = channel
        self.identity = identity
        self.ephemeralKey = ephemeralKey
        self.makeSRPClient = makeSRPClient
    }

    /// Verifies the host identity and creates the device-side TLS listener.
    func createTunnelListener() async throws -> RemotePairingTunnelListener {
        try await beginPairVerification()
        let keys = try await verifyIdentity()
        let port = try await requestTCPListener(using: keys)
        return RemotePairingTunnelListener(port: port, preSharedKey: keys.preSharedKey)
    }

    /// Verifies the identity, invoking manual pair setup only when it is unknown.
    ///
    /// - Parameter willEstablishTrust: Called immediately before manual pair
    ///   setup starts after an authentication or unknown-peer rejection.
    func establishTrustIfNeeded(
        willEstablishTrust: () -> Void = {}
    ) async throws {
        try await beginPairVerification()
        do {
            _ = try await verifyIdentity()
        } catch let error as RorkDeviceError {
            guard case let .remotePairing(rejection) = error,
                  rejection.allowsPairSetup else {
                throw error
            }
            willEstablishTrust()
            try await establishTrust()
        }
    }

    /// Starts the wire-protocol handshake and verifies the expected response shape.
    private func beginPairVerification() async throws {
        try await sendPlain([
            "request": [
                "_0": [
                    "handshake": [
                        "_0": [
                            "hostOptions": [
                                "attemptPairVerify": true,
                            ],
                            "wireProtocolVersion": 19,
                        ],
                    ],
                ],
            ],
        ])
        let response = try await receivePlain()
        guard remotePairingNestedDictionary(
            response,
            keys: ["response", "_1", "handshake", "_0"]
        ) != nil else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing handshake response is missing response._1.handshake._0."
            )
        }
    }

    /// Performs HomeKit-style pair verification and derives directional session keys.
    private func verifyIdentity() async throws -> VerifiedRemotePairingKeys {
        let hostPublicKey = ephemeralKey.publicKey.rawRepresentation
        try await sendPairingData(
            TLV8.encode([
                TLV8Field(type: 0x06, value: Data([0x01])),
                TLV8Field(type: 0x03, value: hostPublicKey),
            ]),
            kind: "verifyManualPairing",
            startsNewSession: true
        )

        let deviceResponse = try TLV8.decode(try await receivePairingData())
        try validatePairVerificationResponse(
            deviceResponse,
            expectedState: 0x02
        )
        let devicePublicKeyData = deviceResponse.value(for: 0x03)
        guard devicePublicKeyData.count == 32 else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing device public key must contain 32 bytes."
            )
        }

        let devicePublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            devicePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKeyData)
        } catch {
            throw RorkDeviceError.protocolViolation("Remote pairing device public key is invalid.")
        }
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
        } catch {
            throw RorkDeviceError.secureSession("Remote pairing key agreement failed.")
        }
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let pairVerifyKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32
        )

        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.privateKeyData)
        } catch {
            throw RorkDeviceError.invalidPairingRecord("Remote pairing private key is invalid.")
        }
        var signedMessage = Data()
        signedMessage.append(hostPublicKey)
        signedMessage.append(Data(identity.identifier.utf8))
        signedMessage.append(devicePublicKeyData)
        let signature: Data
        do {
            signature = try signingKey.signature(for: signedMessage)
        } catch {
            throw RorkDeviceError.secureSession("Remote pairing identity signing failed.")
        }

        let encryptedContents = try encrypt(
            TLV8.encode([
                TLV8Field(type: 0x01, value: Data(identity.identifier.utf8)),
                TLV8Field(type: 0x0a, value: signature),
            ]),
            using: pairVerifyKey,
            nonce: Data([0, 0, 0, 0]) + Data("PV-Msg03".utf8)
        )
        try await sendPairingData(
            TLV8.encode([
                TLV8Field(type: 0x06, value: Data([0x03])),
                TLV8Field(type: 0x05, value: encryptedContents),
            ]),
            kind: "verifyManualPairing",
            startsNewSession: false
        )

        let verificationResponse = try TLV8.decode(try await receivePairingData())
        do {
            try validatePairVerificationResponse(
                verificationResponse,
                expectedState: 0x04
            )
        } catch {
            try? await sendPairVerificationFailed()
            throw error
        }

        return VerifiedRemotePairingKeys(
            preSharedKey: sharedSecretData,
            hostToDeviceCipher: deriveSessionKey(
                from: sharedSecretData,
                context: "ClientEncrypt-main"
            ),
            deviceToHostCipher: deriveSessionKey(
                from: sharedSecretData,
                context: "ServerEncrypt-main"
            )
        )
    }

    /// Completes SRP pair setup and registers the host identity with the device.
    private func establishTrust() async throws {
        try await sendPairingData(
            TLV8.encode([
                TLV8Field(type: 0x00, value: Data([0x00])),
                TLV8Field(type: 0x06, value: Data([0x01])),
            ]),
            kind: "setupManualPairing",
            startsNewSession: true
        )
        _ = try await receivePlain()

        let deviceParameters = try TLV8.decode(
            try await receivePairingData()
        )
        try validatePairSetupResponse(
            deviceParameters,
            expectedState: 0x02
        )
        let devicePublicKey = deviceParameters.value(for: 0x03)
        let salt = deviceParameters.value(for: 0x02)
        guard !devicePublicKey.isEmpty, !salt.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Remote pair setup did not provide SRP parameters."
            )
        }

        let exchange = try makeSRPClient().start(
            salt: salt,
            serverPublicKey: devicePublicKey
        )
        try await sendPairingData(
            TLV8.encode([
                TLV8Field(type: 0x06, value: Data([0x03])),
                TLV8Field(type: 0x03, value: exchange.clientPublicKey),
                TLV8Field(type: 0x04, value: exchange.clientProof),
            ]),
            kind: "setupManualPairing",
            startsNewSession: false
        )

        let proofResponse = try TLV8.decode(
            try await receivePairingData()
        )
        try validatePairSetupResponse(
            proofResponse,
            expectedState: 0x04
        )
        try exchange.verify(serverProof: proofResponse.value(for: 0x04))

        try await exchangeIdentity(using: exchange.sessionKey)
        try await createRemoteUnlockKey(using: exchange.sessionKey)
    }

    /// Signs and encrypts the host metadata stored by remote pairing.
    private func exchangeIdentity(using sessionKey: Data) async throws {
        let controllerSigningKey = deriveKey(
            from: sessionKey,
            salt: "Pair-Setup-Controller-Sign-Salt",
            context: "Pair-Setup-Controller-Sign-Info"
        )
        var signedData = controllerSigningKey
        signedData.append(Data(identity.identifier.utf8))
        signedData.append(identity.publicKeyData)

        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identity.privateKeyData
            )
        } catch {
            throw RorkDeviceError.invalidPairingRecord(
                "Remote pairing private key is invalid."
            )
        }
        let signature: Data
        do {
            signature = try signingKey.signature(for: signedData)
        } catch {
            throw RorkDeviceError.secureSession(
                "Remote pairing identity signing failed."
            )
        }

        let deviceInfo = try RemotePairingOPACKEncoder.encode([
            "accountID": identity.identifier,
            "altIRK": identity.identityResolvingKey,
            "btAddr": "00:00:00:00:00:00",
            "mac": Data(repeating: 0, count: 6),
            "model": "RorkDevice",
            "name": "Rork Companion",
            "remotepairing_serial_number": identity.identifier,
        ])
        let identityData = TLV8.encode([
            TLV8Field(type: 0x0a, value: signature),
            TLV8Field(type: 0x03, value: identity.publicKeyData),
            TLV8Field(type: 0x01, value: Data(identity.identifier.utf8)),
            TLV8Field(type: 0x11, value: deviceInfo),
        ])
        let setupEncryptionKey = symmetricKey(
            from: sessionKey,
            salt: "Pair-Setup-Encrypt-Salt",
            context: "Pair-Setup-Encrypt-Info"
        )
        let encryptedIdentity = try encrypt(
            identityData,
            using: setupEncryptionKey,
            nonce: Data([0, 0, 0, 0]) + Data("PS-Msg05".utf8)
        )

        try await sendPairingData(
            TLV8.encode([
                TLV8Field(type: 0x06, value: Data([0x05])),
                TLV8Field(type: 0x05, value: encryptedIdentity),
            ]),
            kind: "setupManualPairing",
            startsNewSession: false,
            sendingHost: "Rork Companion"
        )

        let response = try TLV8.decode(try await receivePairingData())
        try validatePairSetupResponse(response, expectedState: 0x06)
        _ = try decrypt(
            response.value(for: 0x05),
            using: setupEncryptionKey,
            nonce: Data([0, 0, 0, 0]) + Data("PS-Msg06".utf8)
        )
    }

    /// Finalizes pair setup by requesting the device's remote-unlock material.
    private func createRemoteUnlockKey(using sessionKey: Data) async throws {
        let keys = sessionKeys(from: sessionKey)
        _ = try await exchangeEncryptedMessage(
            [
                "request": [
                    "_0": [
                        "createRemoteUnlockKey": [:],
                    ],
                ],
            ],
            using: keys
        )
    }

    /// Requests a TCP listener using the keys established by pair verification.
    private func requestTCPListener(using keys: VerifiedRemotePairingKeys) async throws -> UInt16 {
        let request: [String: Any] = [
            "request": [
                "_0": [
                    "createListener": [
                        "key": keys.preSharedKey.base64EncodedString(),
                        "transportProtocolType": "tcp",
                    ],
                ],
            ],
        ]
        let response = try await exchangeEncryptedMessage(
            request,
            using: keys
        )
        guard let portValue = remotePairingNestedValue(
                  response,
                  keys: ["response", "_1", "createListener", "port"]
              ),
              let port = RemotePairingJSONValue.positiveUInt16(
                  from: portValue
              ) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing listener response is missing a valid port."
            )
        }
        return port
    }

    /// Exchanges one JSON request over the authenticated encrypted stream.
    private func exchangeEncryptedMessage(
        _ request: [String: Any],
        using keys: VerifiedRemotePairingKeys
    ) async throws -> [String: Any] {
        let plaintext = try JSONSerialization.data(withJSONObject: request)
        let nonce = encryptedMessageNonce(
            sequenceNumber: encryptionSequenceNumber
        )
        let ciphertext = try encrypt(
            plaintext,
            using: keys.hostToDeviceCipher,
            nonce: nonce
        )
        try await sendEncrypted(ciphertext)

        let encryptedResponse = try await channel.receiveEncrypted()
        let decrypted = try decrypt(
            encryptedResponse,
            using: keys.deviceToHostCipher,
            nonce: nonce
        )
        encryptionSequenceNumber += 1

        do {
            guard let response = try JSONSerialization.jsonObject(
                with: decrypted
            ) as? [String: Any] else {
                throw RorkDeviceError.protocolViolation(
                    "Remote pairing encrypted response is not a JSON object."
                )
            }
            return response
        } catch let error as RorkDeviceError {
            throw error
        } catch {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing encrypted response is not valid JSON."
            )
        }
    }

    /// Sends one pairing TLV through the outer plain-message envelope.
    private func sendPairingData(
        _ data: Data,
        kind: String,
        startsNewSession: Bool,
        sendingHost: String = ""
    ) async throws {
        try await sendPlain([
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": [
                            "data": data,
                            "kind": kind,
                            "sendingHost": sendingHost,
                            "startNewSession": startsNewSession,
                        ],
                    ],
                ],
            ],
        ])
    }

    /// Receives and base64-decodes one pairing TLV payload.
    private func receivePairingData() async throws -> Data {
        let response = try await receivePlain()
        let encodedData = remotePairingNestedValue(
            response,
            keys: ["event", "_0", "pairingData", "_0", "data"]
        )
        if let data = encodedData as? Data {
            return data
        }
        if let base64 = encodedData as? String,
           let data = Data(base64Encoded: base64) {
            return data
        }
        throw RorkDeviceError.protocolViolation(
            "Remote pairing response is missing pairing data."
        )
    }

    /// Notifies the device that its final verification response was rejected.
    private func sendPairVerificationFailed() async throws {
        try await sendPlain([
            "event": [
                "_0": [
                    "pairVerifyFailed": [:],
                ],
            ],
        ])
    }

    /// Sends one unencrypted outer protocol message.
    private func sendPlain(_ payload: [String: Any]) async throws {
        try await channel.sendPlain(payload)
    }

    /// Sends one encrypted payload inside the outer protocol envelope.
    private func sendEncrypted(_ ciphertext: Data) async throws {
        try await channel.sendEncrypted(ciphertext)
    }

    /// Receives one outer message and extracts its unencrypted payload.
    private func receivePlain() async throws -> [String: Any] {
        try await channel.receivePlain()
    }
}

/// Validates one pair-verification response without hiding trust rejection.
private func validatePairVerificationResponse(
    _ tlv: TLV8,
    expectedState: UInt8
) throws {
    if let rejection = remotePairingRejection(in: tlv) {
        throw RorkDeviceError.remotePairing(rejection)
    }

    guard tlv.value(for: 0x06) == Data([expectedState]) else {
        throw RorkDeviceError.protocolViolation(
            "Remote pairing response has an unexpected pair-verification state."
        )
    }
}

/// Validates the state and optional error returned during manual pair setup.
private func validatePairSetupResponse(
    _ tlv: TLV8,
    expectedState: UInt8
) throws {
    if let rejection = remotePairingRejection(in: tlv) {
        throw RorkDeviceError.remotePairing(rejection)
    }
    guard tlv.value(for: 0x06) == Data([expectedState]) else {
        throw RorkDeviceError.protocolViolation(
            "Remote pair setup returned an unexpected state."
        )
    }
}

/// Decodes the protocol's error and optional retry-delay TLVs.
private func remotePairingRejection(
    in tlv: TLV8
) -> RemotePairingRejection? {
    guard let code = tlv.value(for: 0x07).first else {
        return nil
    }

    switch code {
    case 0x01:
        return .unknown
    case 0x02:
        return .authentication
    case 0x03:
        return .backoff(
            retryDelay: retryDelay(from: tlv.value(for: 0x08))
        )
    case 0x04:
        return .unknownPeer
    case 0x05:
        return .maximumPeers
    case 0x06:
        return .maximumAttempts
    default:
        return .unrecognized(code: code)
    }
}

/// Decodes a little-endian retry delay expressed in whole seconds.
private func retryDelay(from data: Data) -> Duration? {
    guard !data.isEmpty, data.count <= MemoryLayout<UInt64>.size else {
        return nil
    }

    var seconds: UInt64 = 0
    for (index, byte) in data.enumerated() {
        seconds |= UInt64(byte) << (index * 8)
    }
    guard seconds <= UInt64(Int64.max) else {
        return nil
    }
    return .seconds(Int64(seconds))
}

/// Derives the directional ciphers used after pairing or pair verification.
private func sessionKeys(from secret: Data) -> VerifiedRemotePairingKeys {
    VerifiedRemotePairingKeys(
        preSharedKey: secret,
        hostToDeviceCipher: deriveSessionKey(
            from: secret,
            context: "ClientEncrypt-main"
        ),
        deviceToHostCipher: deriveSessionKey(
            from: secret,
            context: "ServerEncrypt-main"
        )
    )
}

/// Derives one directional ChaCha20-Poly1305 key from the shared secret.
private func deriveSessionKey(from secret: Data, context: String) -> SymmetricKey {
    HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(),
        info: Data(context.utf8),
        outputByteCount: 32
    )
}

/// Derives raw key material for a named pair-setup operation.
private func deriveKey(
    from secret: Data,
    salt: String,
    context: String
) -> Data {
    symmetricKey(
        from: secret,
        salt: salt,
        context: context
    ).withUnsafeBytes { Data($0) }
}

/// Derives one pair-setup key using Apple's protocol labels.
private func symmetricKey(
    from secret: Data,
    salt: String,
    context: String
) -> SymmetricKey {
    HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(salt.utf8),
        info: Data(context.utf8),
        outputByteCount: 32
    )
}

/// Encodes the protocol's 64-bit sequence number as a 96-bit ChaCha nonce.
private func encryptedMessageNonce(sequenceNumber: UInt64) -> Data {
    var nonce = Data()
    nonce.appendLittleEndian(sequenceNumber)
    nonce.append(Data(repeating: 0, count: 4))
    return nonce
}

/// Encrypts and authenticates a protocol payload without serializing the nonce.
private func encrypt(_ plaintext: Data, using key: SymmetricKey, nonce: Data) throws -> Data {
    let sealed: ChaChaPoly.SealedBox
    do {
        sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: nonce)
        )
    } catch {
        throw RorkDeviceError.secureSession("Remote pairing encryption failed.")
    }
    return sealed.ciphertext + sealed.tag
}

/// Authenticates and decrypts a protocol payload using its externally derived nonce.
private func decrypt(_ ciphertextAndTag: Data, using key: SymmetricKey, nonce: Data) throws -> Data {
    guard ciphertextAndTag.count >= 16 else {
        throw RorkDeviceError.protocolViolation("Remote pairing encrypted response is too short.")
    }
    let tagOffset = ciphertextAndTag.count - 16
    do {
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertextAndTag.prefix(tagOffset),
            tag: ciphertextAndTag.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key)
    } catch {
        throw RorkDeviceError.secureSession("Remote pairing response authentication failed.")
    }
}
