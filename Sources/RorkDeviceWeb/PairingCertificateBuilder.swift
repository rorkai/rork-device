import Foundation

/// Builds the narrow X.509 profile required by Lockdown pairing.
///
/// Browser cryptography can generate and sign RSA keys but does not construct
/// certificates. This builder owns only deterministic DER assembly. Key
/// generation, SHA-1 hashing, and RSA signing remain delegated to the caller so
/// the browser adapter can use Web Crypto without introducing a second native
/// cryptography dependency into the WASM target.
enum PairingCertificateBuilder {
    /// Public-key encodings needed by certificate assembly and key identifiers.
    struct PublicKey: Equatable, Sendable {
        /// Complete SubjectPublicKeyInfo DER embedded in a certificate.
        let subjectPublicKeyInfo: Data

        /// PKCS#1 RSA key bytes carried by SubjectPublicKeyInfo's bit string.
        let subjectPublicKey: Data
    }

    /// Certificate constraints applied to one member of the pairing hierarchy.
    enum Role: Sendable {
        /// Self-signed root allowed to issue the host and device leaves.
        case certificateAuthority

        /// Non-CA host or device certificate.
        case leaf
    }

    /// RSA signer supplied by the platform cryptography backend.
    typealias Signer = (Data) async throws -> Data

    /// Creates one SHA-1-with-RSA certificate used by Lockdown.
    ///
    /// Empty issuer and subject names intentionally match the long-standing
    /// usbmux pairing format. The root receives CA and certificate-signing
    /// constraints; leaves receive digital-signature and key-encipherment
    /// usage. Every certificate includes the RFC 5280 SHA-1 key identifier
    /// supplied by the caller.
    ///
    /// - Parameters:
    ///   - publicKeyInfo: RSA SubjectPublicKeyInfo in DER form.
    ///   - subjectKeyIdentifier: SHA-1 digest of the public-key bit string.
    ///   - validFrom: Beginning of the certificate validity interval.
    ///   - validUntil: End of the certificate validity interval.
    ///   - role: Constraints for a root or leaf certificate.
    ///   - signer: RSA PKCS#1 v1.5 SHA-1 signer for the generated TBS bytes.
    /// - Returns: Complete DER-encoded X.509 certificate.
    /// - Throws: A validation, DER-encoding, or platform signing error.
    @MainActor
    static func certificate(
        publicKeyInfo: Data,
        subjectKeyIdentifier: Data,
        validFrom: Date,
        validUntil: Date,
        role: Role,
        signer: Signer
    ) async throws -> Data {
        _ = try subjectPublicKey(from: publicKeyInfo)
        guard subjectKeyIdentifier.count == 20 else {
            throw PairingCertificateError.invalidSubjectKeyIdentifier
        }
        guard validFrom < validUntil else {
            throw PairingCertificateError.invalidValidityInterval
        }

        let signatureAlgorithm = DER.sequence([
            try DER.objectIdentifier([1, 2, 840, 113_549, 1, 1, 5]),
            DER.null,
        ])
        let emptyName = DER.sequence([])
        let validity = DER.sequence([
            try DER.utcTime(validFrom),
            try DER.utcTime(validUntil),
        ])
        let extensions = try DER.sequence(
            certificateExtensions(
                role: role,
                subjectKeyIdentifier: subjectKeyIdentifier
            )
        )
        let tbsCertificate = DER.sequence([
            DER.explicit(tagNumber: 0, DER.integer(2)),
            DER.integer(0),
            signatureAlgorithm,
            emptyName,
            validity,
            emptyName,
            .init(encodedBytes: Array(publicKeyInfo)),
            DER.explicit(tagNumber: 3, extensions),
        ])
        let signature = try await signer(Data(tbsCertificate.encodedBytes))
        guard !signature.isEmpty else {
            throw PairingCertificateError.emptySignature
        }

        return Data(
            DER.sequence([
                tbsCertificate,
                signatureAlgorithm,
                DER.bitString(Array(signature)),
            ]).encodedBytes
        )
    }

    /// Decodes the RSA public-key formats accepted from Lockdown.
    ///
    /// Devices normally return `RSA PUBLIC KEY` PEM containing PKCS#1 bytes.
    /// `PUBLIC KEY` SubjectPublicKeyInfo is also accepted for compatibility
    /// with pairing records produced by other tooling.
    static func publicKey(fromPEM data: Data) throws -> PublicKey {
        guard let string = String(data: data, encoding: .utf8) else {
            throw PairingCertificateError.invalidPEMEncoding
        }
        let document = try PEMDocument(string)

        switch document.discriminator {
        case "RSA PUBLIC KEY":
            guard !document.derBytes.isEmpty else {
                throw PairingCertificateError.emptyPublicKey
            }
            let subjectPublicKeyInfo = DER.sequence([
                DER.sequence([
                    try DER.objectIdentifier([
                        1, 2, 840, 113_549, 1, 1, 1,
                    ]),
                    DER.null,
                ]),
                DER.bitString(Array(document.derBytes)),
            ])
            return PublicKey(
                subjectPublicKeyInfo: Data(
                    subjectPublicKeyInfo.encodedBytes
                ),
                subjectPublicKey: document.derBytes
            )

        case "PUBLIC KEY":
            return PublicKey(
                subjectPublicKeyInfo: document.derBytes,
                subjectPublicKey: Data(
                    try subjectPublicKey(from: document.derBytes)
                )
            )

        default:
            throw PairingCertificateError.unsupportedPEMDiscriminator(
                document.discriminator
            )
        }
    }

    /// Encodes DER bytes in PEM armor with conventional 64-character lines.
    static func pem(
        discriminator: String,
        derBytes: Data
    ) -> Data {
        let base64 = derBytes.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(
                start,
                offsetBy: min(64, base64.distance(from: start, to: base64.endIndex))
            )
            return String(base64[start..<end])
        }
        let text =
            (["-----BEGIN \(discriminator)-----"]
            + lines
            + ["-----END \(discriminator)-----", ""]).joined(separator: "\n")
        return Data(text.utf8)
    }

    /// Creates the extension set for one certificate role.
    private static func certificateExtensions(
        role: Role,
        subjectKeyIdentifier: Data
    ) throws -> [DER] {
        let basicConstraints: DER
        let keyUsage: DER
        let basicConstraintsAreCritical: Bool

        switch role {
        case .certificateAuthority:
            basicConstraints = DER.sequence([DER.boolean(true)])
            keyUsage = DER.bitString([0x04], unusedBitCount: 2)
            basicConstraintsAreCritical = true

        case .leaf:
            basicConstraints = DER.sequence([])
            keyUsage = DER.bitString([0xA0], unusedBitCount: 5)
            basicConstraintsAreCritical = false
        }

        return [
            try certificateExtension(
                objectIdentifier: [2, 5, 29, 19],
                critical: basicConstraintsAreCritical,
                value: basicConstraints
            ),
            try certificateExtension(
                objectIdentifier: [2, 5, 29, 15],
                critical: false,
                value: keyUsage
            ),
            try certificateExtension(
                objectIdentifier: [2, 5, 29, 14],
                critical: false,
                value: DER.octetString(
                    Array(subjectKeyIdentifier)
                )
            ),
        ]
    }

    /// Wraps one extension value in the RFC 5280 extension envelope.
    private static func certificateExtension(
        objectIdentifier: [UInt64],
        critical: Bool,
        value: DER
    ) throws -> DER {
        var fields = [
            try DER.objectIdentifier(objectIdentifier)
        ]
        if critical {
            fields.append(DER.boolean(true))
        }
        fields.append(DER.octetString(value.encodedBytes))
        return DER.sequence(fields)
    }

    /// Extracts the key bytes from a complete RSA SubjectPublicKeyInfo value.
    private static func subjectPublicKey(
        from subjectPublicKeyInfo: Data
    ) throws -> [UInt8] {
        let outer = try DERReader.singleElement(in: Array(subjectPublicKeyInfo))
        guard outer.tag == 0x30 else {
            throw PairingCertificateError.invalidSubjectPublicKeyInfo
        }

        var children = DERReader(bytes: outer.content)
        let algorithm = try children.readElement()
        let key = try children.readElement()
        guard algorithm.tag == 0x30,
            key.tag == 0x03,
            children.isAtEnd,
            key.content.first == 0,
            key.content.count > 1
        else {
            throw PairingCertificateError.invalidSubjectPublicKeyInfo
        }
        return Array(key.content.dropFirst())
    }
}

/// Stable failures produced while constructing browser pairing credentials.
private enum PairingCertificateError: Error, LocalizedError {
    case emptyPublicKey
    case emptySignature
    case invalidPEMDocument
    case invalidPEMEncoding
    case invalidSubjectKeyIdentifier
    case invalidSubjectPublicKeyInfo
    case invalidValidityInterval
    case malformedDER
    case unsupportedPEMDiscriminator(String)
    case unsupportedUTCTimeYear(Int)

    var errorDescription: String? {
        switch self {
        case .emptyPublicKey:
            return "The Lockdown public key is empty."
        case .emptySignature:
            return "The cryptography backend returned an empty RSA signature."
        case .invalidPEMDocument:
            return "The Lockdown public key is not a valid PEM document."
        case .invalidPEMEncoding:
            return "The Lockdown public key is not valid UTF-8 PEM."
        case .invalidSubjectKeyIdentifier:
            return "An X.509 subject key identifier must contain 20 bytes."
        case .invalidSubjectPublicKeyInfo:
            return "The RSA SubjectPublicKeyInfo value is malformed."
        case .invalidValidityInterval:
            return "The certificate validity interval is empty or reversed."
        case .malformedDER:
            return "The ASN.1 DER value is malformed."
        case .unsupportedPEMDiscriminator(let discriminator):
            return "Unsupported public-key PEM type \(discriminator)."
        case .unsupportedUTCTimeYear(let year):
            return "The year \(year) cannot be represented as ASN.1 UTCTime."
        }
    }
}

/// Minimal PEM decoder used for Lockdown RSA public keys.
private struct PEMDocument {
    /// Text between the BEGIN and END markers.
    let discriminator: String

    /// Base64-decoded DER payload.
    let derBytes: Data

    /// Parses exactly one PEM document.
    init(_ string: String) throws {
        let lines =
            string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first,
            first.hasPrefix("-----BEGIN "),
            first.hasSuffix("-----"),
            let last = lines.last,
            last.hasPrefix("-----END "),
            last.hasSuffix("-----")
        else {
            throw PairingCertificateError.invalidPEMDocument
        }

        let beginStart = first.index(
            first.startIndex,
            offsetBy: "-----BEGIN ".count
        )
        let beginEnd = first.index(first.endIndex, offsetBy: -5)
        let endStart = last.index(
            last.startIndex,
            offsetBy: "-----END ".count
        )
        let endEnd = last.index(last.endIndex, offsetBy: -5)
        let discriminator = String(first[beginStart..<beginEnd])
        guard discriminator == String(last[endStart..<endEnd]),
            lines.count >= 3,
            let data = Data(
                base64Encoded: lines[1..<(lines.count - 1)].joined()
            )
        else {
            throw PairingCertificateError.invalidPEMDocument
        }

        self.discriminator = discriminator
        derBytes = data
    }
}

/// Small DER value used to assemble the fixed Lockdown certificate profile.
private struct DER {
    /// Complete tag-length-value bytes.
    let encodedBytes: [UInt8]

    /// ASN.1 NULL.
    static let null = tagged(0x05, content: [])

    /// Encodes a constructed sequence.
    static func sequence(_ values: [DER]) -> DER {
        tagged(
            0x30,
            content: values.flatMap(\.encodedBytes)
        )
    }

    /// Encodes a nonnegative integer.
    static func integer(_ value: UInt8) -> DER {
        var bytes = [value]
        if value & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tagged(0x02, content: bytes)
    }

    /// Encodes an ASN.1 Boolean.
    static func boolean(_ value: Bool) -> DER {
        tagged(0x01, content: [value ? 0xFF : 0x00])
    }

    /// Encodes an ASN.1 object identifier.
    static func objectIdentifier(_ arcs: [UInt64]) throws -> DER {
        guard arcs.count >= 2,
            arcs[0] <= 2,
            arcs[0] == 2 || arcs[1] < 40
        else {
            throw PairingCertificateError.malformedDER
        }

        var bytes = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) {
            bytes.append(contentsOf: base128(arc))
        }
        return tagged(0x06, content: bytes)
    }

    /// Encodes an ASN.1 bit string.
    static func bitString(
        _ bytes: [UInt8],
        unusedBitCount: UInt8 = 0
    ) -> DER {
        precondition(unusedBitCount < 8)
        precondition(
            unusedBitCount == 0
                || bytes.last.map {
                    $0 & UInt8((1 << unusedBitCount) - 1) == 0
                } == true
        )
        return tagged(
            0x03,
            content: [unusedBitCount] + bytes
        )
    }

    /// Encodes an ASN.1 octet string.
    static func octetString(_ bytes: [UInt8]) -> DER {
        tagged(0x04, content: bytes)
    }

    /// Encodes a context-specific explicit value.
    static func explicit(
        tagNumber: UInt8,
        _ value: DER
    ) -> DER {
        precondition(tagNumber < 31)
        return tagged(
            0xA0 | tagNumber,
            content: value.encodedBytes
        )
    }

    /// Encodes a UTC date in the canonical DER form.
    static func utcTime(_ date: Date) throws -> DER {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute,
            let second = components.second,
            (1950...2049).contains(year)
        else {
            throw PairingCertificateError.unsupportedUTCTimeYear(
                components.year ?? 0
            )
        }

        let value = [
            twoDigits(year % 100),
            twoDigits(month),
            twoDigits(day),
            twoDigits(hour),
            twoDigits(minute),
            twoDigits(second),
            "Z",
        ].joined()
        return tagged(0x17, content: Array(value.utf8))
    }

    /// Encodes a complete DER tag-length-value node.
    private static func tagged(
        _ tag: UInt8,
        content: [UInt8]
    ) -> DER {
        DER(
            encodedBytes: [tag] + encodedLength(content.count) + content
        )
    }

    /// Encodes one nonnegative value in ASN.1 base-128 form.
    private static func base128(_ value: UInt64) -> [UInt8] {
        guard value > 0 else {
            return [0]
        }
        var value = value
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.append(UInt8(value & 0x7F))
            value >>= 7
        }
        bytes.reverse()
        for index in bytes.indices.dropLast() {
            bytes[index] |= 0x80
        }
        return bytes
    }

    /// Encodes a canonical DER content length.
    private static func encodedLength(_ length: Int) -> [UInt8] {
        precondition(length >= 0)
        guard length >= 0x80 else {
            return [UInt8(length)]
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
        bytes.reverse()
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// Formats one decimal field in ASN.1 time.
    private static func twoDigits(_ value: Int) -> String {
        precondition((0...99).contains(value))
        return "\(value / 10)\(value % 10)"
    }
}

/// Bounds-checked reader for the small DER structures accepted from Web Crypto.
private struct DERReader {
    /// Bytes still owned by this reader.
    let bytes: [UInt8]

    /// Offset of the next tag.
    private(set) var offset = 0

    /// Whether every byte has been consumed.
    var isAtEnd: Bool {
        offset == bytes.count
    }

    /// Parses one complete top-level value and rejects trailing bytes.
    static func singleElement(in bytes: [UInt8]) throws -> Element {
        var reader = DERReader(bytes: bytes)
        let element = try reader.readElement()
        guard reader.isAtEnd else {
            throw PairingCertificateError.malformedDER
        }
        return element
    }

    /// Reads one tag-length-value node.
    mutating func readElement() throws -> Element {
        guard offset < bytes.count else {
            throw PairingCertificateError.malformedDER
        }
        let tag = bytes[offset]
        offset += 1
        let length = try readLength()
        guard length <= bytes.count - offset else {
            throw PairingCertificateError.malformedDER
        }
        let content = Array(bytes[offset..<(offset + length)])
        offset += length
        return Element(tag: tag, content: content)
    }

    /// Reads a canonical DER length field.
    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else {
            throw PairingCertificateError.malformedDER
        }
        let first = bytes[offset]
        offset += 1
        guard first & 0x80 != 0 else {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0,
            byteCount <= MemoryLayout<Int>.size,
            byteCount <= bytes.count - offset,
            bytes[offset] != 0
        else {
            throw PairingCertificateError.malformedDER
        }

        var length = 0
        for byte in bytes[offset..<(offset + byteCount)] {
            guard length <= (Int.max - Int(byte)) / 256 else {
                throw PairingCertificateError.malformedDER
            }
            length = length * 256 + Int(byte)
        }
        offset += byteCount
        guard length >= 0x80 else {
            throw PairingCertificateError.malformedDER
        }
        return length
    }

    /// Parsed tag and content bytes.
    struct Element {
        let tag: UInt8
        let content: [UInt8]
    }
}
