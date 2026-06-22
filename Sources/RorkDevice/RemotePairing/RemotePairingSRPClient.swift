#if canImport(BigInt)
import BigInt
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Values produced by the SRP-6a client for one manual pair-setup exchange.
struct RemotePairingSRPExchange {
    /// Ephemeral public value sent to the device in the pair-setup M3 message.
    let clientPublicKey: Data

    /// Client authenticator sent alongside `clientPublicKey`.
    let clientProof: Data

    /// SHA-512 session key used by the encrypted pair-setup messages.
    let sessionKey: Data

    /// Server authenticator calculated from this exchange.
    private let expectedServerProof: Data

    /// Creates the immutable result of one SRP calculation.
    init(
        clientPublicKey: Data,
        clientProof: Data,
        sessionKey: Data,
        expectedServerProof: Data
    ) {
        self.clientPublicKey = clientPublicKey
        self.clientProof = clientProof
        self.sessionKey = sessionKey
        self.expectedServerProof = expectedServerProof
    }

    /// Verifies that the device derived the same SRP session key.
    ///
    /// - Parameter serverProof: Authenticator returned in the pair-setup M4
    ///   message.
    /// - Throws: `RorkDeviceError.secureSession` when the authenticator differs.
    func verify(serverProof: Data) throws {
        guard expectedServerProof.constantTimeEquals(serverProof) else {
            throw RorkDeviceError.secureSession(
                "Remote pairing returned an invalid SRP server proof."
            )
        }
    }
}

/// RFC 5054 SRP-6a client configured for Apple's manual pair-setup credentials.
struct RemotePairingSRPClient {
    /// RFC 5054 3072-bit safe prime.
    private static let modulus = BigUInt(
        Data(
            hexadecimal: """
                FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
                020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
                4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
                EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
                98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
                9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
                E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
                3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
                A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
                ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
                D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
                08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
                """)
    )

    /// Generator assigned to the RFC 5054 3072-bit group.
    private static let generator = BigUInt(5)

    /// Serialized byte width of every padded SRP group value.
    private static let groupByteCount = 384

    /// Username and password fixed by Apple's manual pair-setup protocol.
    private static let username = Data("Pair-Setup".utf8)
    private static let password = Data("000000".utf8)

    /// Random client exponent retained for one SRP exchange.
    private let privateKey: BigUInt

    /// Creates a client with cryptographically random ephemeral state.
    init() throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        try self.init(privateKey: bytes)
    }

    /// Creates a deterministic client for protocol tests.
    init(privateKey: Data) throws {
        let privateKey = BigUInt(privateKey)
        guard privateKey > 0 else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing SRP private key must be nonzero."
            )
        }
        self.privateKey = privateKey
    }

    /// Derives the client public value, proof, and shared session key.
    ///
    /// - Parameters:
    ///   - salt: Device-provided SRP salt.
    ///   - serverPublicKey: Device-provided SRP public value.
    /// - Returns: Values required to complete pair setup and verify the device.
    /// - Throws: `RorkDeviceError.secureSession` for invalid peer values.
    func start(
        salt: Data,
        serverPublicKey: Data
    ) throws -> RemotePairingSRPExchange {
        let modulus = Self.modulus
        let generator = Self.generator
        let serverPublicKey = BigUInt(serverPublicKey)
        guard serverPublicKey > 0,
            serverPublicKey < modulus,
            serverPublicKey % modulus != 0
        else {
            throw RorkDeviceError.secureSession(
                "Remote pairing returned an invalid SRP public key."
            )
        }

        let clientPublicKey = generator.power(privateKey, modulus: modulus)
        let multiplier = BigUInt(
            sha512(Self.serialize(modulus) + Self.padded(generator))
        )
        let passwordHash = sha512(
            Self.username + Data(":".utf8) + Self.password
        )
        let privateKeyHash = BigUInt(sha512(salt + passwordHash))
        let scramblingParameter = BigUInt(
            sha512(
                Self.padded(clientPublicKey)
                    + Self.padded(serverPublicKey)
            )
        )
        guard scramblingParameter > 0 else {
            throw RorkDeviceError.secureSession(
                "Remote pairing produced a zero SRP scrambling parameter."
            )
        }

        let verifier = generator.power(privateKeyHash, modulus: modulus)
        let blindedVerifier = multiplier * verifier % modulus
        let base = (serverPublicKey + modulus - blindedVerifier) % modulus
        let exponent = privateKey + scramblingParameter * privateKeyHash
        let sharedSecret = base.power(exponent, modulus: modulus)
        let sessionKey = sha512(Self.serialize(sharedSecret))

        let modulusHash = sha512(Self.serialize(modulus))
        let generatorHash = sha512(Self.serialize(generator))
        let groupHash = modulusHash.xor(generatorHash)
        let clientProof = sha512(
            groupHash
                + sha512(Self.username)
                + salt
                + Self.serialize(clientPublicKey)
                + Self.serialize(serverPublicKey)
                + sessionKey
        )
        let serverProof = sha512(
            Self.serialize(clientPublicKey)
                + clientProof
                + sessionKey
        )

        return RemotePairingSRPExchange(
            clientPublicKey: Self.serialize(clientPublicKey),
            clientProof: clientProof,
            sessionKey: sessionKey,
            expectedServerProof: serverProof
        )
    }

    /// Serializes a positive integer without leading zero padding.
    private static func serialize(_ value: BigUInt) -> Data {
        value.serialize()
    }

    /// Serializes one group value at the modulus width.
    private static func padded(_ value: BigUInt) -> Data {
        let serialized = serialize(value)
        guard serialized.count < groupByteCount else {
            return serialized
        }
        return Data(repeating: 0, count: groupByteCount - serialized.count)
            + serialized
    }
}

/// Returns the SHA-512 digest of one byte buffer.
private func sha512(_ data: Data) -> Data {
    Data(SHA512.hash(data: data))
}

extension Data {
    /// Decodes a static hexadecimal constant after removing formatting whitespace.
    fileprivate init(hexadecimal value: String) {
        let hexadecimal = value.filter { !$0.isWhitespace }
        precondition(hexadecimal.count.isMultiple(of: 2))

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let nextIndex = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<nextIndex], radix: 16) else {
                preconditionFailure("Static hexadecimal constant is invalid.")
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }

    /// Computes a byte-wise exclusive OR over equal-length buffers.
    fileprivate func xor(_ other: Data) -> Data {
        precondition(count == other.count)
        return Data(zip(self, other).map(^))
    }

    /// Compares equal-length authentication values without early exit.
    fileprivate func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else {
            return false
        }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(self, other) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}
#endif
