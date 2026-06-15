/// A TLS cipher suite selected for remote-pairing packet traffic.
///
/// The raw value is the 16-bit code assigned by IANA. Known suites expose their
/// registered name, while unknown values remain representable so diagnostics do
/// not discard information introduced by newer devices or TLS implementations.
public struct RemotePairingTLSCipherSuite:
    RawRepresentable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    /// The 16-bit cipher-suite code transmitted during the TLS handshake.
    public let rawValue: UInt16

    /// Creates a cipher suite from its IANA wire value.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The registered IANA name, or `nil` when the suite is unknown.
    public var ianaName: String? {
        switch rawValue {
        case 0x00A9:
            "TLS_PSK_WITH_AES_256_GCM_SHA384"
        case 0x00A8:
            "TLS_PSK_WITH_AES_128_GCM_SHA256"
        case 0x00AF:
            "TLS_PSK_WITH_AES_256_CBC_SHA384"
        case 0x00AE:
            "TLS_PSK_WITH_AES_128_CBC_SHA256"
        case 0x008D:
            "TLS_PSK_WITH_AES_256_CBC_SHA"
        case 0x008C:
            "TLS_PSK_WITH_AES_128_CBC_SHA"
        default:
            nil
        }
    }

    /// A stable diagnostic containing the IANA name and hexadecimal wire value.
    public var description: String {
        "\(ianaName ?? "unknown TLS cipher suite") (\(hexadecimalCode))"
    }

    /// The wire value formatted as four uppercase hexadecimal digits.
    private var hexadecimalCode: String {
        let digits = String(rawValue, radix: 16, uppercase: true)
        return "0x\(String(repeating: "0", count: 4 - digits.count))\(digits)"
    }
}
