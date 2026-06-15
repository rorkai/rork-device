import Foundation

/// Value types supported by the RemoteXPC object encoding used for discovery.
enum RemoteXPCValue: Equatable {
    /// Explicit null object.
    case null

    /// Boolean object encoded with a four-byte payload.
    case bool(Bool)

    /// Signed 64-bit integer object.
    case int64(Int64)

    /// Unsigned 64-bit integer object.
    case uint64(UInt64)

    /// IEEE 754 double-precision object.
    case double(Double)

    /// Raw signed date representation carried by RemoteXPC.
    case date(Int64)

    /// Arbitrary byte buffer.
    case data(Data)

    /// Null-terminated UTF-8 string.
    case string(String)

    /// UUID represented by its exact 16 wire bytes.
    case uuid(Data)

    /// Ordered collection of RemoteXPC values.
    case array([RemoteXPCValue])

    /// String-keyed collection of RemoteXPC values.
    case dictionary([String: RemoteXPCValue])

    /// Returns the associated dictionary without forcing callers to pattern match.
    var dictionaryValue: [String: RemoteXPCValue]? {
        guard case let .dictionary(value) = self else {
            return nil
        }
        return value
    }

    /// Returns the associated string without forcing callers to pattern match.
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    /// Converts integer and decimal-string representations to a native `Int`.
    var integerValue: Int? {
        switch self {
        case let .int64(value):
            return Int(exactly: value)
        case let .uint64(value):
            return Int(exactly: value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }
}

/// Decoded RemoteXPC wrapper and its optional object payload.
struct RemoteXPCMessage: Equatable {
    /// Wrapper flags controlling channel semantics.
    let flags: UInt32

    /// Protocol-level message identifier.
    let messageIdentifier: UInt64

    /// Decoded object, or `nil` when the wrapper has an empty body.
    let value: RemoteXPCValue?
}

/// Encodes and decodes RemoteXPC wrappers and version 5 object bodies.
enum RemoteXPCMessageCodec {
    /// Fixed magic at the beginning of each RemoteXPC wrapper.
    private static let wrapperMagic: UInt32 = 0x29b00b92

    /// Fixed magic at the beginning of each nonempty object body.
    private static let objectMagic: UInt32 = 0x42133742

    /// Object encoding version supported by this implementation.
    private static let objectVersion: UInt32 = 5

    /// Largest RemoteXPC body accepted from the discovery connection.
    ///
    /// Service advertisements are normally only a few kilobytes. The 16 MiB
    /// ceiling leaves substantial headroom while preventing an untrusted peer
    /// from driving unbounded buffering with a forged wrapper length.
    private static let maximumDiscoveryBodyLength = 16 * 1024 * 1024

    /// RemoteXPC object tags supported by the discovery protocol.
    private enum ObjectType: UInt32 {
        /// Explicit null value.
        case null = 0x00001000

        /// Four-byte boolean value.
        case bool = 0x00002000

        /// Signed 64-bit integer.
        case int64 = 0x00003000

        /// Unsigned 64-bit integer.
        case uint64 = 0x00004000

        /// IEEE 754 double-precision value.
        case double = 0x00005000

        /// Signed 64-bit date representation.
        case date = 0x00007000

        /// Length-prefixed byte buffer.
        case data = 0x00008000

        /// Length-prefixed, null-terminated UTF-8 string.
        case string = 0x00009000

        /// Exact 16-byte UUID representation.
        case uuid = 0x0000a000

        /// Length-prefixed array container.
        case array = 0x0000e000

        /// Length-prefixed dictionary container.
        case dictionary = 0x0000f000
    }

    /// Encodes one wrapper and its optional RemoteXPC value.
    static func encode(
        value: RemoteXPCValue?,
        flags: UInt32,
        messageIdentifier: UInt64
    ) throws -> Data {
        let body = try value.map(encodeBody) ?? Data()
        var data = Data()
        data.appendLittleEndian(wrapperMagic)
        data.appendLittleEndian(flags)
        data.appendLittleEndian(UInt64(body.count))
        data.appendLittleEndian(messageIdentifier)
        data.append(body)
        return data
    }

    /// Decodes the first complete wrapper in a stream buffer.
    ///
    /// - Returns: The message and consumed byte count, or `nil` when more bytes
    ///   are required to complete the wrapper.
    static func decodeFirstMessage(
        from data: Data
    ) throws -> (message: RemoteXPCMessage, consumedByteCount: Int)? {
        guard data.count >= 24 else {
            return nil
        }

        let magic: UInt32 = try data.littleEndianInteger(at: 0)
        guard magic == wrapperMagic else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC message has invalid wrapper magic 0x\(String(magic, radix: 16))."
            )
        }

        let flags: UInt32 = try data.littleEndianInteger(at: 4)
        let bodyLength: UInt64 = try data.littleEndianInteger(at: 8)
        guard let bodyLength = Int(exactly: bodyLength),
              bodyLength <= Int.max - 24 else {
            throw RorkDeviceError.protocolViolation("RemoteXPC message body is too large.")
        }
        guard bodyLength <= maximumDiscoveryBodyLength else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC message body exceeds the 16 MiB discovery limit."
            )
        }

        let messageLength = 24 + bodyLength
        guard data.count >= messageLength else {
            return nil
        }

        let messageIdentifier: UInt64 = try data.littleEndianInteger(at: 16)
        let value: RemoteXPCValue?
        if bodyLength == 0 {
            value = nil
        } else {
            var reader = RemoteXPCDataReader(data: Data(data[24..<messageLength]))
            value = try decodeBody(from: &reader)
            guard reader.isAtEnd else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC message contains \(reader.remainingCount) trailing body bytes."
                )
            }
        }

        return (
            RemoteXPCMessage(
                flags: flags,
                messageIdentifier: messageIdentifier,
                value: value
            ),
            messageLength
        )
    }

    /// Encodes the object body header followed by one value.
    private static func encodeBody(_ value: RemoteXPCValue) throws -> Data {
        var body = Data()
        body.appendLittleEndian(objectMagic)
        body.appendLittleEndian(objectVersion)
        try encode(value, into: &body)
        return body
    }

    /// Appends one tagged RemoteXPC value to an object body.
    private static func encode(_ value: RemoteXPCValue, into data: inout Data) throws {
        switch value {
        case .null:
            data.appendLittleEndian(ObjectType.null.rawValue)

        case let .bool(value):
            data.appendLittleEndian(ObjectType.bool.rawValue)
            data.append(value ? 1 : 0)
            data.append(contentsOf: [0, 0, 0])

        case let .int64(value):
            data.appendLittleEndian(ObjectType.int64.rawValue)
            data.appendLittleEndian(value)

        case let .uint64(value):
            data.appendLittleEndian(ObjectType.uint64.rawValue)
            data.appendLittleEndian(value)

        case let .double(value):
            data.appendLittleEndian(ObjectType.double.rawValue)
            data.appendLittleEndian(value.bitPattern)

        case let .date(value):
            data.appendLittleEndian(ObjectType.date.rawValue)
            data.appendLittleEndian(value)

        case let .data(value):
            data.appendLittleEndian(ObjectType.data.rawValue)
            data.appendLittleEndian(UInt32(value.count))
            data.append(value)
            appendAlignmentPadding(for: value.count, to: &data)

        case let .string(value):
            guard let encoded = value.data(using: .utf8) else {
                throw RorkDeviceError.invalidInput("RemoteXPC string is not valid UTF-8.")
            }
            let payloadLength = encoded.count + 1
            data.appendLittleEndian(ObjectType.string.rawValue)
            data.appendLittleEndian(UInt32(payloadLength))
            data.append(encoded)
            data.append(0)
            appendAlignmentPadding(for: payloadLength, to: &data)

        case let .uuid(value):
            guard value.count == 16 else {
                throw RorkDeviceError.invalidInput(
                    "RemoteXPC UUID values must contain exactly 16 bytes."
                )
            }
            data.appendLittleEndian(ObjectType.uuid.rawValue)
            data.append(value)

        case let .array(values):
            var payload = Data()
            payload.appendLittleEndian(UInt32(values.count))
            for value in values {
                try encode(value, into: &payload)
            }
            data.appendLittleEndian(ObjectType.array.rawValue)
            data.appendLittleEndian(UInt32(payload.count))
            data.append(payload)

        case let .dictionary(values):
            var payload = Data()
            payload.appendLittleEndian(UInt32(values.count))
            for key in values.keys.sorted() {
                guard let encodedKey = key.data(using: .utf8),
                      let value = values[key] else {
                    throw RorkDeviceError.invalidInput(
                        "RemoteXPC dictionary contains an invalid UTF-8 key."
                    )
                }
                let keyLength = encodedKey.count + 1
                payload.append(encodedKey)
                payload.append(0)
                appendAlignmentPadding(for: keyLength, to: &payload)
                try encode(value, into: &payload)
            }
            data.appendLittleEndian(ObjectType.dictionary.rawValue)
            data.appendLittleEndian(UInt32(payload.count))
            data.append(payload)
        }
    }

    /// Validates an object body header and decodes its single root value.
    private static func decodeBody(from reader: inout RemoteXPCDataReader) throws -> RemoteXPCValue {
        let magic: UInt32 = try reader.readLittleEndian()
        guard magic == objectMagic else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC body has invalid object magic 0x\(String(magic, radix: 16))."
            )
        }

        let version: UInt32 = try reader.readLittleEndian()
        guard version == objectVersion else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC body uses unsupported version \(version)."
            )
        }
        return try decodeValue(from: &reader)
    }

    /// Decodes one tagged RemoteXPC value from an object body.
    private static func decodeValue(from reader: inout RemoteXPCDataReader) throws -> RemoteXPCValue {
        let rawType: UInt32 = try reader.readLittleEndian()
        guard let type = ObjectType(rawValue: rawType) else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC object uses unsupported type 0x\(String(rawType, radix: 16))."
            )
        }

        switch type {
        case .null:
            return .null

        case .bool:
            let raw = try reader.read(count: 4)
            return .bool(raw.first != 0)

        case .int64:
            return .int64(try reader.readLittleEndian())

        case .uint64:
            return .uint64(try reader.readLittleEndian())

        case .double:
            let bits: UInt64 = try reader.readLittleEndian()
            return .double(Double(bitPattern: bits))

        case .date:
            return .date(try reader.readLittleEndian())

        case .data:
            let length: UInt32 = try reader.readLittleEndian()
            let value = try reader.read(count: Int(length))
            try reader.skipAlignmentPadding(for: Int(length))
            return .data(value)

        case .string:
            let length: UInt32 = try reader.readLittleEndian()
            let raw = try reader.read(count: Int(length))
            try reader.skipAlignmentPadding(for: Int(length))
            guard raw.last == 0,
                  let value = String(data: raw.dropLast(), encoding: .utf8) else {
                throw RorkDeviceError.protocolViolation(
                    "RemoteXPC string is missing its terminator or is not valid UTF-8."
                )
            }
            return .string(value)

        case .uuid:
            return .uuid(try reader.read(count: 16))

        case .array:
            let payloadLength: UInt32 = try reader.readLittleEndian()
            return .array(
                try reader.withBoundedPayload(length: Int(payloadLength)) { payload in
                    let count: UInt32 = try payload.readLittleEndian()
                    var values: [RemoteXPCValue] = []
                    values.reserveCapacity(Int(count))
                    for _ in 0..<count {
                        values.append(try decodeValue(from: &payload))
                    }
                    return values
                }
            )

        case .dictionary:
            let payloadLength: UInt32 = try reader.readLittleEndian()
            return .dictionary(
                try reader.withBoundedPayload(length: Int(payloadLength)) { payload in
                    let count: UInt32 = try payload.readLittleEndian()
                    var values: [String: RemoteXPCValue] = [:]
                    values.reserveCapacity(Int(count))
                    for _ in 0..<count {
                        let key = try payload.readAlignedCString()
                        values[key] = try decodeValue(from: &payload)
                    }
                    return values
                }
            )

        }
    }

    /// Pads a variable-length payload to the protocol's four-byte alignment.
    private static func appendAlignmentPadding(for length: Int, to data: inout Data) {
        let padding = (4 - length % 4) % 4
        if padding > 0 {
            data.append(Data(repeating: 0, count: padding))
        }
    }
}

/// Bounds-checked cursor for decoding one RemoteXPC object body.
private struct RemoteXPCDataReader {
    /// Immutable bytes covered by this reader.
    let data: Data

    /// Offset of the next unread byte.
    private(set) var offset = 0

    /// Whether the reader consumed its complete bounded payload.
    var isAtEnd: Bool {
        offset == data.count
    }

    /// Number of bytes available from the current offset.
    var remainingCount: Int {
        data.count - offset
    }

    /// Reads one fixed-width integer in RemoteXPC's little-endian byte order.
    mutating func readLittleEndian<T: FixedWidthInteger>(
        _ type: T.Type = T.self
    ) throws -> T {
        let value = try data.littleEndianInteger(at: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return value
    }

    /// Reads exactly `count` bytes and advances the cursor.
    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC body ended \(count - remainingCount) bytes early."
            )
        }
        defer {
            offset += count
        }
        return Data(data[offset..<(offset + count)])
    }

    /// Consumes the padding that aligns a payload of `length` bytes to four bytes.
    mutating func skipAlignmentPadding(for length: Int) throws {
        _ = try read(count: (4 - length % 4) % 4)
    }

    /// Reads one aligned, null-terminated UTF-8 dictionary key.
    mutating func readAlignedCString() throws -> String {
        guard let terminator = data[offset...].firstIndex(of: 0) else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC dictionary key is missing its terminator."
            )
        }
        let encoded = Data(data[offset..<terminator])
        let encodedLength = terminator - offset + 1
        offset = terminator + 1
        try skipAlignmentPadding(for: encodedLength)
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC dictionary key is not valid UTF-8."
            )
        }
        return value
    }

    /// Restricts a nested decoder to one length-prefixed container payload.
    mutating func withBoundedPayload<T>(
        length: Int,
        _ body: (inout RemoteXPCDataReader) throws -> T
    ) throws -> T {
        let payloadData = try read(count: length)
        var payload = RemoteXPCDataReader(data: payloadData)
        let value = try body(&payload)
        guard payload.isAtEnd else {
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC container contains \(payload.remainingCount) trailing bytes."
            )
        }
        return value
    }
}
