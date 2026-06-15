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
    /// Plain control stream connected to the remote-pairing endpoint.
    private let connection: DeviceConnection

    /// Previously trusted host identity presented during pair verification.
    private let identity: RemotePairingIdentity

    /// Per-session X25519 key used to establish the shared secret.
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    /// Sequence number attached to each outer remote-pairing message.
    private var messageSequenceNumber = 0

    /// Sequence number used to derive nonces for encrypted stream messages.
    private var encryptionSequenceNumber: UInt64 = 0

    /// Creates a protocol driver over an established control stream.
    init(
        connection: DeviceConnection,
        identity: RemotePairingIdentity,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) {
        self.connection = connection
        self.identity = identity
        self.ephemeralKey = ephemeralKey
    }

    /// Verifies the host identity and creates the device-side TLS listener.
    func createTunnelListener() async throws -> RemotePairingTunnelListener {
        try await beginPairVerification()
        let keys = try await verifyIdentity()
        let port = try await requestTCPListener(using: keys)
        return RemotePairingTunnelListener(port: port, preSharedKey: keys.preSharedKey)
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
        guard nestedDictionary(response, keys: ["response", "_1", "handshake", "_0"]) != nil else {
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
            startsNewSession: true
        )

        let deviceResponse = try TLV8.decode(try await receivePairingData())
        try validatePairingResponse(deviceResponse)
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
            startsNewSession: false
        )

        let verificationResponse = try TLV8.decode(try await receivePairingData())
        do {
            try validatePairingResponse(verificationResponse)
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
        let plaintext = try JSONSerialization.data(withJSONObject: request)
        let nonce = encryptedMessageNonce(sequenceNumber: encryptionSequenceNumber)
        let ciphertext = try encrypt(
            plaintext,
            using: keys.hostToDeviceCipher,
            nonce: nonce
        )
        try await sendEncrypted(ciphertext)

        let responseFrame = try await RemotePairingFrameCodec.receive(from: connection)
        guard let encryptedBase64 = nestedValue(
            responseFrame,
            keys: ["message", "streamEncrypted", "_0"]
        ) as? String,
              let encryptedResponse = Data(base64Encoded: encryptedBase64) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing listener response is missing encrypted data."
            )
        }
        let decrypted = try decrypt(
            encryptedResponse,
            using: keys.deviceToHostCipher,
            nonce: nonce
        )
        encryptionSequenceNumber += 1

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: decrypted)
        } catch {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing listener response is not valid JSON."
            )
        }
        guard let response = object as? [String: Any],
              let portValue = nestedValue(
                  response,
                  keys: ["response", "_1", "createListener", "port"]
              ),
              let port = portNumber(from: portValue) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing listener response is missing a valid port."
            )
        }
        return port
    }

    /// Sends a pair-verification TLV through the outer plain-message envelope.
    private func sendPairingData(_ data: Data, startsNewSession: Bool) async throws {
        try await sendPlain([
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": [
                            "data": data.base64EncodedString(),
                            "kind": "verifyManualPairing",
                            "startNewSession": startsNewSession,
                        ],
                    ],
                ],
            ],
        ])
    }

    /// Receives and base64-decodes one pair-verification TLV payload.
    private func receivePairingData() async throws -> Data {
        let response = try await receivePlain()
        guard let base64 = nestedValue(
            response,
            keys: ["event", "_0", "pairingData", "_0", "data"]
        ) as? String,
              let data = Data(base64Encoded: base64) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing response is missing pairing data."
            )
        }
        return data
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
        let frame = try RemotePairingFrameCodec.encode([
            "message": [
                "plain": [
                    "_0": payload,
                ],
            ],
            "originatedBy": "host",
            "sequenceNumber": messageSequenceNumber,
        ])
        try await connection.send(frame)
        messageSequenceNumber += 1
    }

    /// Sends one encrypted payload inside the outer protocol envelope.
    private func sendEncrypted(_ ciphertext: Data) async throws {
        let frame = try RemotePairingFrameCodec.encode([
            "message": [
                "streamEncrypted": [
                    "_0": ciphertext.base64EncodedString(),
                ],
            ],
            "originatedBy": "host",
            "sequenceNumber": messageSequenceNumber,
        ])
        try await connection.send(frame)
        messageSequenceNumber += 1
    }

    /// Receives one outer message and extracts its unencrypted payload.
    private func receivePlain() async throws -> [String: Any] {
        let frame = try await RemotePairingFrameCodec.receive(from: connection)
        guard let payload = nestedDictionary(frame, keys: ["message", "plain", "_0"]) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing response is missing a plain message payload."
            )
        }
        return payload
    }
}

/// Rejects a pair-verification response containing the protocol error field.
private func validatePairingResponse(_ tlv: TLV8) throws {
    let errorValue = tlv.value(for: 0x07)
    guard let code = errorValue.first else {
        return
    }
    throw RorkDeviceError.protocolViolation(
        "Remote pairing rejected this host identity with error \(code)."
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

/// Reads a nested JSON dictionary at the supplied key path.
private func nestedDictionary(_ dictionary: [String: Any], keys: [String]) -> [String: Any]? {
    nestedValue(dictionary, keys: keys) as? [String: Any]
}

/// Reads an arbitrary nested JSON value at the supplied key path.
private func nestedValue(_ dictionary: [String: Any], keys: [String]) -> Any? {
    var value: Any = dictionary
    for key in keys {
        guard let current = value as? [String: Any], let next = current[key] else {
            return nil
        }
        value = next
    }
    return value
}

/// Converts a JSON number into a valid, nonzero TCP port.
private func portNumber(from value: Any) -> UInt16? {
    let integer: Int?
    if let value = value as? Int {
        integer = value
    } else if let value = value as? NSNumber {
        integer = value.intValue
    } else {
        integer = nil
    }
    guard let integer, integer > 0, integer <= Int(UInt16.max) else {
        return nil
    }
    return UInt16(integer)
}
