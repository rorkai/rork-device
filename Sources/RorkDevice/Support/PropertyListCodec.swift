import Foundation

/// Thin wrapper around Foundation plist serialization.
enum PropertyListCodec {
    /// Encodes a plist-compatible value.
    static func encode(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    /// Decodes XML or binary plist bytes.
    static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
}

/// Big-endian length-prefixed plist framing used by Lockdown-style services.
enum PropertyListMessageFramer {
    /// Encodes a dictionary as a length-prefixed plist message.
    static func encode(_ dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        let payload = try PropertyListCodec.encode(dictionary, format: format)
        guard payload.count <= UInt32.max else {
            throw RorkDeviceError.invalidInput("Property list message exceeds UInt32 length.")
        }

        var data = Data()
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    /// Sends one length-prefixed plist dictionary.
    static func send(_ dictionary: [String: Any], to connection: DeviceConnection) async throws {
        try await connection.send(encode(dictionary))
    }

    /// Receives one length-prefixed plist dictionary.
    static func receive(from connection: DeviceConnection) async throws -> [String: Any] {
        let lengthData = try await connection.receive(count: 4)
        let length = try Int(lengthData.bigEndianInteger(at: 0, as: UInt32.self))
        let payload = try await connection.receive(count: length)
        guard let dictionary = try PropertyListCodec.decode(payload) as? [String: Any] else {
            throw RorkDeviceError.protocolViolation("Expected property list dictionary response.")
        }
        return dictionary
    }
}

/// Typed extraction helpers for decoded plist dictionaries.
extension Dictionary where Key == String, Value == Any {
    /// Returns a string field.
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    /// Returns a boolean field, accepting `NSNumber` for plist compatibility.
    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    /// Returns an integer field, accepting `NSNumber` for plist compatibility.
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }
}
