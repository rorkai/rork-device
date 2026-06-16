import Foundation
import XCTest
@testable import RorkDevice

final class CoreDeviceUserspaceTransportTests: XCTestCase {
    func testEncodesTheDestinationPreamble() throws {
        let preamble = try CoreDeviceUserspaceTransport.destinationPreamble(
            address: "fd92:fbe0:acf3::2",
            port: 49_152
        )

        XCTAssertEqual(
            preamble,
            Data([
                0xfd, 0x92, 0xfb, 0xe0, 0xac, 0xf3, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
                0x00, 0xc0, 0x00, 0x00,
            ])
        )
    }

    func testRejectsAnInvalidDeviceAddressAtInitialization() {
        XCTAssertThrowsError(
            try CoreDeviceUserspaceTransport(
                deviceAddress: "not-an-ipv6-address",
                gatewayPort: 60_106
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "CoreDevice userspace transport requires a valid IPv6 device address."
                )
            )
        }
    }
}
