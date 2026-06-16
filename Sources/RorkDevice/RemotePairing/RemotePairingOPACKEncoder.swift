import Foundation

/// Encodes the compact OPACK subset used by remote-pairing device metadata.
///
/// Pair setup sends one small dictionary whose keys and string values are UTF-8
/// and whose binary fields are `Data`. Rejecting every other shape keeps this
/// private encoder bounded to the protocol surface RorkDevice actually uses.
enum RemotePairingOPACKEncoder {
    /// Encodes a dictionary in stable key order.
    static func encode(_ dictionary: [String: Any]) throws -> Data {
        guard dictionary.count <= 15 else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing OPACK dictionaries support at most 15 entries."
            )
        }

        var encoded = Data([0xe0 | UInt8(dictionary.count)])
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] else {
                continue
            }
            try appendString(key, to: &encoded)
            switch value {
            case let value as String:
                try appendString(value, to: &encoded)
            case let value as Data:
                try appendData(value, to: &encoded)
            default:
                throw RorkDeviceError.invalidInput(
                    "Remote pairing OPACK values must be strings or data."
                )
            }
        }
        return encoded
    }

    /// Appends one UTF-8 string with its OPACK length marker.
    private static func appendString(
        _ value: String,
        to encoded: inout Data
    ) throws {
        let data = Data(value.utf8)
        try appendLengthMarker(base: 0x40, count: data.count, to: &encoded)
        encoded.append(data)
    }

    /// Appends one byte buffer with its OPACK length marker.
    private static func appendData(
        _ value: Data,
        to encoded: inout Data
    ) throws {
        try appendLengthMarker(base: 0x70, count: value.count, to: &encoded)
        encoded.append(value)
    }

    /// Encodes the compact, extended-nibble, or one-byte length form.
    private static func appendLengthMarker(
        base: UInt8,
        count: Int,
        to encoded: inout Data
    ) throws {
        switch count {
        case 0...15:
            encoded.append(base | UInt8(count))
        case 16...31:
            encoded.append((base + 0x10) | UInt8(count & 0x0f))
        case 32...255:
            encoded.append(base + 0x21)
            encoded.append(UInt8(count))
        default:
            throw RorkDeviceError.invalidInput(
                "Remote pairing OPACK values cannot exceed 255 bytes."
            )
        }
    }
}
