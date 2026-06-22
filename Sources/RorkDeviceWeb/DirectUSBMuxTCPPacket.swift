import Foundation

/// Flags carried by the TCP-compatible stream header inside usbmux.
struct DirectUSBMuxTCPFlags: OptionSet, Equatable, Sendable {
    /// Raw eight-bit TCP flag field.
    let rawValue: UInt8

    /// The sender has finished transmitting.
    static let finish = Self(rawValue: 0x01)

    /// Opens a virtual service connection.
    static let synchronize = Self(rawValue: 0x02)

    /// Aborts a virtual service connection.
    static let reset = Self(rawValue: 0x04)

    /// Requests prompt delivery of the attached payload.
    static let push = Self(rawValue: 0x08)

    /// Confirms received sequence data and advertises a receive window.
    static let acknowledgment = Self(rawValue: 0x10)
}

/// TCP-compatible frame carried by direct USB mux protocol six.
///
/// Apple uses the standard fixed TCP header layout to multiplex device service
/// streams, but the frame is not an IP packet. Checksums and urgent data are
/// therefore unused, while ports, sequence numbers, acknowledgements, flags,
/// and the scaled receive window retain their TCP meanings.
struct DirectUSBMuxTCPPacket: Equatable, Sendable {
    /// Size of the TCP header emitted by this implementation.
    static let headerLength = 20

    /// Host-side virtual port.
    let sourcePort: UInt16

    /// Device-side service port.
    let destinationPort: UInt16

    /// Sequence number of the first payload byte.
    let sequenceNumber: UInt32

    /// Next sequence number expected from the peer.
    let acknowledgmentNumber: UInt32

    /// Connection-control flags.
    let flags: DirectUSBMuxTCPFlags

    /// Receive window before the protocol's fixed eight-bit scale is applied.
    let windowSize: UInt16

    /// Service bytes carried by the frame.
    let payload: Data

    /// Encodes the fixed header and payload in network byte order.
    func encoded() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.appendBigEndian(sourcePort)
        data.appendBigEndian(destinationPort)
        data.appendBigEndian(sequenceNumber)
        data.appendBigEndian(acknowledgmentNumber)
        data.append(UInt8(Self.headerLength / 4) << 4)
        data.append(flags.rawValue)
        data.appendBigEndian(windowSize)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt16(0))
        data.append(payload)
        return data
    }

    /// Decodes one TCP-compatible usbmux frame.
    ///
    /// TCP options are skipped according to the data-offset field even though
    /// this implementation emits only the fixed twenty-byte header.
    static func decode(_ data: Data) throws -> Self {
        guard data.count >= Self.headerLength else {
            throw DirectUSBMuxTCPPacketError.headerTooShort(
                actual: data.count
            )
        }

        let dataOffsetIndex = data.index(
            data.startIndex,
            offsetBy: 12
        )
        let flagsIndex = data.index(
            data.startIndex,
            offsetBy: 13
        )
        let headerLength = Int(data[dataOffsetIndex] >> 4) * 4
        guard headerLength >= Self.headerLength,
            headerLength <= data.count
        else {
            throw DirectUSBMuxTCPPacketError.invalidHeaderLength(
                actual: headerLength,
                packetLength: data.count
            )
        }

        return Self(
            sourcePort: data.bigEndianInteger(
                at: 0,
                as: UInt16.self
            ),
            destinationPort: data.bigEndianInteger(
                at: 2,
                as: UInt16.self
            ),
            sequenceNumber: data.bigEndianInteger(
                at: 4,
                as: UInt32.self
            ),
            acknowledgmentNumber: data.bigEndianInteger(
                at: 8,
                as: UInt32.self
            ),
            flags: DirectUSBMuxTCPFlags(rawValue: data[flagsIndex]),
            windowSize: data.bigEndianInteger(
                at: 14,
                as: UInt16.self
            ),
            payload: Data(
                data[
                    data.index(
                        data.startIndex,
                        offsetBy: headerLength
                    )...
                ]
            )
        )
    }
}

/// Reports malformed TCP-compatible usbmux frames.
enum DirectUSBMuxTCPPacketError: Error, Equatable {
    /// The frame cannot contain the required fixed header.
    case headerTooShort(actual: Int)

    /// The TCP data-offset field points outside the packet.
    case invalidHeaderLength(actual: Int, packetLength: Int)
}
