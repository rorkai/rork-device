import Foundation
import XCTest

@testable import RorkDeviceWeb

final class DirectUSBMuxPacketCodecTests: XCTestCase {
    func testLegacyVersionPacketUsesEightByteBigEndianHeader() throws {
        let codec = DirectUSBMuxPacketCodec()

        let packet = try codec.encode(
            protocol: .version,
            payload: Data([
                0, 0, 0, 2,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ]),
            header: .legacy
        )

        XCTAssertEqual(
            packet,
            Data([
                0, 0, 0, 0,
                0, 0, 0, 20,
                0, 0, 0, 2,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ])
        )
    }

    func testSequencedSetupPacketIncludesMagicAndSequenceNumbers() throws {
        let codec = DirectUSBMuxPacketCodec()

        let packet = try codec.encode(
            protocol: .setup,
            payload: Data([0x07]),
            header: .sequenced(
                transmitSequence: 0x1234,
                receiveSequence: 0xabcd
            )
        )

        XCTAssertEqual(
            packet,
            Data([
                0, 0, 0, 2,
                0, 0, 0, 17,
                0xfe, 0xed, 0xfa, 0xce,
                0x12, 0x34,
                0xab, 0xcd,
                0x07,
            ])
        )
    }

    func testDecoderRetainsIncompleteLegacyPacketUntilPayloadArrives() throws {
        var decoder = DirectUSBMuxPacketDecoder(headerFormat: .legacy)

        decoder.append(
            Data([
                0, 0, 0, 1,
                0, 0, 0, 11,
                0xaa,
            ])
        )

        XCTAssertNil(try decoder.nextPacket())

        decoder.append(Data([0xbb, 0xcc]))

        XCTAssertEqual(
            try decoder.nextPacket(),
            DirectUSBMuxPacket(
                protocol: .control,
                header: .legacy,
                payload: Data([0xaa, 0xbb, 0xcc])
            )
        )
        XCTAssertNil(try decoder.nextPacket())
    }

    func testDecoderRejectsLengthShorterThanSequencedHeader() throws {
        var decoder = DirectUSBMuxPacketDecoder(headerFormat: .sequenced)
        decoder.append(
            Data([
                0, 0, 0, 2,
                0, 0, 0, 15,
                0xfe, 0xed, 0xfa, 0xce,
                0, 0,
                0, 0,
            ])
        )

        XCTAssertThrowsError(try decoder.nextPacket()) { error in
            XCTAssertEqual(
                error as? DirectUSBMuxPacketCodecError,
                .invalidPacketLength(actual: 15, minimum: 16)
            )
        }
    }

    func testEncoderRejectsPacketsBeyondBoundedTransportLimit() throws {
        let codec = DirectUSBMuxPacketCodec()

        XCTAssertThrowsError(
            try codec.encode(
                protocol: .tcp,
                payload: Data(
                    repeating: 0,
                    count: DirectUSBMuxPacketCodec.maximumPacketLength
                ),
                header: .legacy
            )
        ) { error in
            XCTAssertEqual(
                error as? DirectUSBMuxPacketCodecError,
                .packetTooLarge(
                    actual:
                        DirectUSBMuxPacketCodec.maximumPacketLength + 8,
                    maximum:
                        DirectUSBMuxPacketCodec.maximumPacketLength
                )
            )
        }
    }
}
