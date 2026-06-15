import Foundation

/// Encodes and decodes the length-prefixed JSON envelope used by remote pairing.
enum RemotePairingFrameCodec {
    /// Fixed protocol prefix present before every frame length.
    static let magic = Data("RPPairing".utf8)

    /// Encodes a JSON dictionary with the protocol magic and a 16-bit length.
    static func encode(_ dictionary: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(dictionary) else {
            throw RorkDeviceError.invalidInput("Remote pairing frame contains a value that JSON cannot encode.")
        }
        let payload = try JSONSerialization.data(withJSONObject: dictionary)
        guard payload.count <= Int(UInt16.max) else {
            throw RorkDeviceError.invalidInput("Remote pairing frame exceeds UInt16 length.")
        }

        var frame = Data()
        frame.append(magic)
        frame.appendBigEndian(UInt16(payload.count))
        frame.append(payload)
        return frame
    }

    /// Receives and validates one complete remote-pairing frame.
    static func receive(from connection: DeviceConnection) async throws -> [String: Any] {
        let receivedMagic = try await connection.receive(exactly: magic.count)
        guard receivedMagic == magic else {
            throw RorkDeviceError.protocolViolation("Remote pairing frame has an invalid magic prefix.")
        }
        let lengthData = try await connection.receive(exactly: 2)
        let length = try Int(lengthData.bigEndianInteger(at: 0, as: UInt16.self))
        guard length > 0 else {
            throw RorkDeviceError.protocolViolation("Remote pairing frame payload is empty.")
        }
        let payload = try await connection.receive(exactly: length)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw RorkDeviceError.protocolViolation("Remote pairing frame payload is not valid JSON.")
        }
        guard let dictionary = object as? [String: Any] else {
            throw RorkDeviceError.protocolViolation("Remote pairing frame payload is not a JSON object.")
        }
        return dictionary
    }
}
