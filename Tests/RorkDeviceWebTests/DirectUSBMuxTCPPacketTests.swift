import Foundation
import XCTest

@testable import RorkDeviceWeb

final class DirectUSBMuxTCPPacketTests: XCTestCase {
    func testPacketRoundTripsHeaderFieldsAndPayload() throws {
        let packet = DirectUSBMuxTCPPacket(
            sourcePort: 49_152,
            destinationPort: 62_078,
            sequenceNumber: 0x0102_0304,
            acknowledgmentNumber: 0x0506_0708,
            flags: [.acknowledgment],
            windowSize: 512,
            payload: Data([0xaa, 0xbb, 0xcc])
        )

        let encoded = packet.encoded()

        XCTAssertEqual(encoded.count, 23)
        XCTAssertEqual(
            try DirectUSBMuxTCPPacket.decode(encoded),
            packet
        )
    }

    func testSYNPacketUsesAHeaderWithoutOptionsOrChecksum() {
        let packet = DirectUSBMuxTCPPacket(
            sourcePort: 49_152,
            destinationPort: 62_078,
            sequenceNumber: 0,
            acknowledgmentNumber: 0,
            flags: [.synchronize],
            windowSize: 512,
            payload: Data()
        )

        XCTAssertEqual(
            packet.encoded(),
            Data([
                0xc0, 0x00,
                0xf2, 0x7e,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0x50,
                0x02,
                0x02, 0x00,
                0, 0,
                0, 0,
            ])
        )
    }

    func testDecoderRejectsTCPHeaderShorterThanTwentyBytes() {
        XCTAssertThrowsError(
            try DirectUSBMuxTCPPacket.decode(
                Data(repeating: 0, count: 19)
            )
        ) { error in
            XCTAssertEqual(
                error as? DirectUSBMuxTCPPacketError,
                .headerTooShort(actual: 19)
            )
        }
    }

    func testDecoderRejectsHeaderLengthBeyondPacketBoundary() {
        var packet = Data(repeating: 0, count: 20)
        packet[12] = 6 << 4

        XCTAssertThrowsError(
            try DirectUSBMuxTCPPacket.decode(packet)
        ) { error in
            XCTAssertEqual(
                error as? DirectUSBMuxTCPPacketError,
                .invalidHeaderLength(actual: 24, packetLength: 20)
            )
        }
    }
}
