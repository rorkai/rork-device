import Foundation

/// One type-length-value field from the remote pair-verification protocol.
struct TLV8Field: Equatable {
    /// Numeric field identifier defined by the pair-verification protocol.
    let type: UInt8

    /// Raw value bytes; values longer than 255 bytes are fragmented on encode.
    let value: Data
}

/// Ordered TLV8 fields used by remote pair verification.
struct TLV8: Equatable {
    /// Decoded fields in wire order, including repeated field types.
    let fields: [TLV8Field]

    /// Concatenates all fragments carrying a particular field type.
    func value(for type: UInt8) -> Data {
        fields.lazy
            .filter { $0.type == type }
            .reduce(into: Data()) { result, field in
                result.append(field.value)
            }
    }

    /// Serializes fields, splitting values into protocol-sized fragments.
    static func encode(_ fields: [TLV8Field]) -> Data {
        var encoded = Data()
        for field in fields {
            if field.value.isEmpty {
                encoded.append(field.type)
                encoded.append(0)
                continue
            }

            var start = field.value.startIndex
            while start < field.value.endIndex {
                let length = min(255, field.value.distance(from: start, to: field.value.endIndex))
                let end = field.value.index(start, offsetBy: length)
                encoded.append(field.type)
                encoded.append(UInt8(length))
                encoded.append(field.value[start..<end])
                start = end
            }
        }
        return encoded
    }

    /// Decodes a complete TLV8 payload while preserving field order.
    static func decode(_ data: Data) throws -> TLV8 {
        var fields: [TLV8Field] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.distance(from: offset, to: data.endIndex) >= 2 else {
                throw RorkDeviceError.protocolViolation("TLV8 header is truncated.")
            }
            let type = data[offset]
            let lengthIndex = data.index(after: offset)
            let length = Int(data[lengthIndex])
            offset = data.index(offset, offsetBy: 2)
            guard data.distance(from: offset, to: data.endIndex) >= length else {
                throw RorkDeviceError.protocolViolation("TLV8 value for type \(type) is truncated.")
            }
            let end = data.index(offset, offsetBy: length)
            fields.append(TLV8Field(type: type, value: data[offset..<end]))
            offset = end
        }
        return TLV8(fields: fields)
    }
}
