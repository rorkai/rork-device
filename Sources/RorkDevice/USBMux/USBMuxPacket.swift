import Foundation

struct USBMuxPacket {
    static let headerLength = 16
    static let plistMessageType: UInt32 = 8
    static let protocolVersion: UInt32 = 1

    let version: UInt32
    let messageType: UInt32
    let tag: UInt32
    let payload: Data

    init(version: UInt32 = Self.protocolVersion, messageType: UInt32 = Self.plistMessageType, tag: UInt32, payload: Data) {
        self.version = version
        self.messageType = messageType
        self.tag = tag
        self.payload = payload
    }

    func encoded() throws -> Data {
        let totalLength = Self.headerLength + payload.count
        guard totalLength <= UInt32.max else {
            throw RorkDeviceError.invalidInput("usbmux packet is too large.")
        }

        var data = Data()
        data.appendLittleEndian(UInt32(totalLength))
        data.appendLittleEndian(version)
        data.appendLittleEndian(messageType)
        data.appendLittleEndian(tag)
        data.append(payload)
        return data
    }

    static func decode(header: Data, payload: Data) throws -> USBMuxPacket {
        guard header.count == headerLength else {
            throw RorkDeviceError.protocolViolation("Invalid usbmux header length \(header.count).")
        }

        let length = try Int(header.littleEndianInteger(at: 0, as: UInt32.self))
        guard length == headerLength + payload.count else {
            throw RorkDeviceError.protocolViolation("usbmux payload length mismatch.")
        }

        return USBMuxPacket(
            version: try header.littleEndianInteger(at: 4, as: UInt32.self),
            messageType: try header.littleEndianInteger(at: 8, as: UInt32.self),
            tag: try header.littleEndianInteger(at: 12, as: UInt32.self),
            payload: payload
        )
    }
}
