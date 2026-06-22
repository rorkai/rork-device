import Foundation

/// Identifies the payload carried by a direct USB mux packet.
///
/// Apple devices use protocol zero for mux negotiation and protocol six for
/// virtual TCP traffic. The remaining values are retained so the codec can
/// validate and represent every packet observed during session setup.
enum DirectUSBMuxProtocol: UInt32, Equatable {
    case version = 0
    case control = 1
    case setup = 2
    case tcp = 6
}

/// Selects the wire header used for a direct USB mux packet.
enum DirectUSBMuxPacketHeader: Equatable {
    /// The initial eight-byte header used before protocol-version negotiation.
    case legacy

    /// The sixteen-byte header used after protocol-version negotiation.
    case sequenced(
        transmitSequence: UInt16,
        receiveSequence: UInt16
    )
}

/// Identifies the header shape expected while decoding incoming packets.
enum DirectUSBMuxPacketHeaderFormat {
    /// The initial eight-byte negotiation header.
    case legacy

    /// The sixteen-byte header carrying mux sequence numbers.
    case sequenced

    /// Number of bytes occupied by this header on the wire.
    var length: Int {
        switch self {
        case .legacy:
            8
        case .sequenced:
            16
        }
    }
}

/// One decoded packet exchanged with Apple's direct USB mux endpoint.
struct DirectUSBMuxPacket: Equatable {
    /// Protocol that owns the packet payload.
    let `protocol`: DirectUSBMuxProtocol

    /// Header metadata carried by the packet.
    let header: DirectUSBMuxPacketHeader

    /// Protocol-specific packet bytes.
    let payload: Data
}

/// Serializes packets exchanged with Apple's direct USB mux endpoint.
///
/// The packet length includes both the header and payload. All integer fields
/// use network byte order, independently of the host running the WASM module.
struct DirectUSBMuxPacketCodec {
    /// Magic value sent by a host using the sequenced packet header.
    private static let hostMagic: UInt32 = 0xfeed_face

    /// The largest packet accepted by the direct USB mux transport.
    ///
    /// Bounding packet sizes protects the browser integration from allocating
    /// unbounded buffers when a device returns malformed framing data.
    static let maximumPacketLength = 256 * 1_024

    /// Encodes one complete packet for transmission to the USB bulk endpoint.
    ///
    /// - Parameters:
    ///   - muxProtocol: The direct USB mux protocol carried by the packet.
    ///   - payload: The protocol-specific packet body.
    ///   - header: The header format active for the current connection phase.
    /// - Returns: A complete packet ready for a WebUSB bulk transfer.
    /// - Throws: ``DirectUSBMuxPacketCodecError/packetTooLarge`` when the
    ///   complete packet exceeds the transport's bounded packet size.
    func encode(
        protocol muxProtocol: DirectUSBMuxProtocol,
        payload: Data,
        header: DirectUSBMuxPacketHeader
    ) throws -> Data {
        let headerLength: Int
        switch header {
        case .legacy:
            headerLength = 8
        case .sequenced:
            headerLength = 16
        }

        let packetLength = headerLength + payload.count
        guard packetLength <= Self.maximumPacketLength else {
            throw DirectUSBMuxPacketCodecError.packetTooLarge(
                actual: packetLength,
                maximum: Self.maximumPacketLength
            )
        }

        var packet = Data(capacity: packetLength)
        packet.appendBigEndian(muxProtocol.rawValue)
        packet.appendBigEndian(UInt32(packetLength))
        if case .sequenced(
            let
                transmitSequence,
            let
                receiveSequence
        ) = header {
            packet.appendBigEndian(Self.hostMagic)
            packet.appendBigEndian(transmitSequence)
            packet.appendBigEndian(receiveSequence)
        }
        packet.append(payload)
        return packet
    }
}

/// Incrementally decodes packets assembled from WebUSB bulk transfers.
///
/// WebUSB reads are not aligned to direct USB mux packet boundaries. The
/// decoder therefore retains incomplete data between transfers and returns
/// only complete, validated packets.
struct DirectUSBMuxPacketDecoder {
    /// Header shape active for the current connection phase.
    private var headerFormat: DirectUSBMuxPacketHeaderFormat

    /// Bytes received from USB that have not formed a complete packet.
    private var bufferedData = Data()

    /// Creates a decoder for one direct USB mux framing phase.
    ///
    /// - Parameter headerFormat: Header shape negotiated for incoming packets.
    init(headerFormat: DirectUSBMuxPacketHeaderFormat) {
        self.headerFormat = headerFormat
    }

    /// Adds bytes from one WebUSB bulk transfer.
    mutating func append(_ data: Data) {
        bufferedData.append(data)
    }

    /// Changes the header expected for packets that remain in the buffer.
    ///
    /// Version negotiation itself uses the legacy header. A version-two device
    /// can place later packets in the same USB transfer, so changing the format
    /// must preserve bytes already buffered by the decoder.
    mutating func useHeaderFormat(
        _ headerFormat: DirectUSBMuxPacketHeaderFormat
    ) {
        self.headerFormat = headerFormat
    }

    /// Returns the next complete packet when enough data has arrived.
    ///
    /// - Returns: The next packet, or `nil` when more USB data is required.
    /// - Throws: ``DirectUSBMuxPacketCodecError`` when the buffered header is
    ///   malformed or names an unsupported protocol.
    mutating func nextPacket() throws -> DirectUSBMuxPacket? {
        let headerLength = headerFormat.length
        guard bufferedData.count >= headerLength else {
            return nil
        }

        let packetLength = Int(
            bufferedData.bigEndianInteger(
                at: 4,
                as: UInt32.self
            )
        )
        guard packetLength >= headerLength else {
            throw DirectUSBMuxPacketCodecError.invalidPacketLength(
                actual: packetLength,
                minimum: headerLength
            )
        }
        guard packetLength <= DirectUSBMuxPacketCodec.maximumPacketLength else {
            throw DirectUSBMuxPacketCodecError.packetTooLarge(
                actual: packetLength,
                maximum: DirectUSBMuxPacketCodec.maximumPacketLength
            )
        }
        guard bufferedData.count >= packetLength else {
            return nil
        }

        let rawProtocol = bufferedData.bigEndianInteger(
            at: 0,
            as: UInt32.self
        )
        guard
            let muxProtocol = DirectUSBMuxProtocol(
                rawValue: rawProtocol
            )
        else {
            throw DirectUSBMuxPacketCodecError.unsupportedProtocol(
                rawProtocol
            )
        }

        let header: DirectUSBMuxPacketHeader
        switch headerFormat {
        case .legacy:
            header = .legacy
        case .sequenced:
            header = .sequenced(
                transmitSequence: bufferedData.bigEndianInteger(
                    at: 12,
                    as: UInt16.self
                ),
                receiveSequence: bufferedData.bigEndianInteger(
                    at: 14,
                    as: UInt16.self
                )
            )
        }

        let payloadStart = bufferedData.index(
            bufferedData.startIndex,
            offsetBy: headerLength
        )
        let payloadEnd = bufferedData.index(
            bufferedData.startIndex,
            offsetBy: packetLength
        )
        let payload = Data(bufferedData[payloadStart..<payloadEnd])
        bufferedData.removeFirst(packetLength)
        return DirectUSBMuxPacket(
            protocol: muxProtocol,
            header: header,
            payload: payload
        )
    }
}

/// Reports malformed or unsupported direct USB mux packet data.
enum DirectUSBMuxPacketCodecError: Error, Equatable {
    /// The packet length is smaller than the active header.
    case invalidPacketLength(actual: Int, minimum: Int)

    /// The complete packet exceeds the codec's bounded allocation limit.
    case packetTooLarge(actual: Int, maximum: Int)

    /// The packet names a direct USB mux protocol this implementation does not
    /// recognize.
    case unsupportedProtocol(UInt32)
}

extension Data {
    /// Appends an integer in network byte order without relying on host layout.
    mutating func appendBigEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) {
            append(contentsOf: $0)
        }
    }

    /// Reads an unaligned integer stored in network byte order.
    func bigEndianInteger<Integer: FixedWidthInteger>(
        at offset: Int,
        as type: Integer.Type
    ) -> Integer {
        let start = index(startIndex, offsetBy: offset)
        let end = index(
            start,
            offsetBy: MemoryLayout<Integer>.size
        )
        return self[start..<end].withUnsafeBytes {
            $0.loadUnaligned(as: Integer.self).bigEndian
        }
    }
}
