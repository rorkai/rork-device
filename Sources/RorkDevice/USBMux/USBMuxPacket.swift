import Foundation

/// Internal representation of the usbmux plist packet envelope.
///
/// usbmux frames each plist payload with a 16-byte little-endian header:
/// total length, protocol version, message type, and request tag.
struct USBMuxPacket {
    /// Size of the fixed usbmux packet header.
    static let headerLength = 16

    /// Message type used by the plist protocol variant.
    static let plistMessageType: UInt32 = 8

    /// Protocol version used by modern plist usbmux requests.
    static let protocolVersion: UInt32 = 1

    /// Header protocol version.
    let version: UInt32

    /// Header message type.
    let messageType: UInt32

    /// Client-generated request tag used to correlate daemon responses.
    let tag: UInt32

    /// Encoded plist payload.
    let payload: Data

    /// Creates a packet from header fields and encoded payload bytes.
    init(version: UInt32 = Self.protocolVersion, messageType: UInt32 = Self.plistMessageType, tag: UInt32, payload: Data) {
        self.version = version
        self.messageType = messageType
        self.tag = tag
        self.payload = payload
    }

    /// Encodes the packet header and payload into usbmux wire format.
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

    /// Decodes a packet after the caller has already split header and payload.
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
