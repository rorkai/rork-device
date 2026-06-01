import Foundation

enum PropertyListCodec {
    static func encode(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
}

enum PropertyListMessageFramer {
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

    static func send(_ dictionary: [String: Any], to connection: DeviceConnection) async throws {
        try await connection.send(encode(dictionary))
    }

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

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

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
