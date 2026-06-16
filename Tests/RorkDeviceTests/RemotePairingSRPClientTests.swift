import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingSRPClientTests: XCTestCase {
    func testProducesTheExpectedPairSetupProofs() throws {
        let client = try RemotePairingSRPClient(
            privateKey: Data((1...32).map(UInt8.init))
        )
        let exchange = try client.start(
            salt: try Data(hexadecimal: "000102030405060708090a0b0c0d0e0f"),
            serverPublicKey: try Data(hexadecimal: """
                7e6059797918050391cb91311f49917a79581a54f73e39ac88268e4429af6c89
                aa16693cef2afa53246006db729bc89423aaef8a7598608c50183a80a8bdc651
                4576d1005125b1fcac3fcbe4ba83e24c96521b390d8e4e5c3d853995df7a69f4
                e1cf9e39aa213a8b6da6c2f024bae6174124f5807c37d127c14880701fec3898
                cd652559fa7aaaae76e60e30c21d4ec4d947b426e88e31dea1bf9888aefc2494
                3c485f71fefd530620c1ba6ae76557130ef8c2fdf134ffb3838bead0dee14a65
                bcaa2442566278b5542c9c0e7b5737f94331e6dcd6da91607ea3b71863b86d3
                f04a73dac1d2aa3dfe29c2c273cff7a953355fb3ea59e450d8f909ae098c3926
                58a45855367136624912eca0bf9022dcb4ee404cc77bbc99c235e020b1a07d017
                ba94e69c82e3ff78c2474cf2fa9239697f99ea511765516987e3256a9d510418
                6aba6f210ff99bac02e36a8018e9999b042b70a05ee1b22e92291532c34bc043
                487486e2c855373c963fe354389ed981c6d3c072af4a8739b8908f704e45b724
                """)
        )

        XCTAssertEqual(
            exchange.clientPublicKey,
            try Data(hexadecimal: """
                bc0e7cf5dc3babf67dcedbb3b140aacc6cac43f4336b43bbd5de48d6ea7c8eda
                66924e354255225bccad9debe21182e6bb050f3ff3e6cfbb62c229379968c70ca
                436ad649a0b051373184215eef046f6f1f2256838f958581f6c7b2b85fa4afe32
                6a0e8a951d4489305331aff88a136fd8d108bcc95fceb7e557c889c828bd23fb0
                702f053e1ca6470fb3c76bce4843fc005c7ea675740f8550212656cfc8919d9db
                805a434a68229e0d9dfe43fc16dc680a5ce74b77cf374353b05759bc1da3a9da
                bde30a4209381c87ca83d9483abdf66b86f9b1cbda9ad82c62712b87ce6fb706
                9b8fc8df344261821a06d0dc5106af76d4245f3f7737a94dbc484b415555dc401
                842d3011204553ba9f611b02bc38de26eba1a76bf8350205a62c436ba1c3c7c69
                d59318bd107fd1c1f5d846b3142e85a5d49e522655e020ed1bfe1e186cf923bf
                328f0b9b4c6a8aa3266ed9125bb98d63827110713be7803122ee4603c54ea3186
                3ce4b10aff31f9073cf63b94733b4f066e72d4ec35687047d5d0db160
                """)
        )
        XCTAssertEqual(
            exchange.clientProof,
            try Data(
                hexadecimal:
                    "9e7457af0c2ef6ca2f43c1f409eb283ba13b23346bf569fac4400e463856b1a8"
                    + "2980bf4fa95488311dca12513ea96c2fc89534bd9190ac19aad54dd65b964cea"
            )
        )
        XCTAssertEqual(
            exchange.sessionKey,
            try Data(
                hexadecimal:
                    "e0071ef3951ca250799e6fc77df75a8c62a5b4bfc9424743fd699fef2ddc4780"
                    + "bd303b0188fc985d79c45aa350705c2883caca77e18710d960e9f6dfe9c44278"
            )
        )
        XCTAssertNoThrow(
            try exchange.verify(
                serverProof: Data(
                    hexadecimal:
                        "82aea05a663dfe562e4b6d7755fb4bcff5fd6a6f94fb540c82971cf8246ac081"
                        + "1dff3588bcdbe24d1e2dee9f265ab9ab971e62d5d08091676522a4e0900ab51a"
                )
            )
        )
    }
}

private extension Data {
    init(hexadecimal value: String) throws {
        let hexadecimal = value.filter { !$0.isWhitespace }
        guard hexadecimal.count.isMultiple(of: 2) else {
            throw RorkDeviceError.invalidInput("Hexadecimal fixture has an odd number of digits.")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let nextIndex = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<nextIndex], radix: 16) else {
                throw RorkDeviceError.invalidInput("Hexadecimal fixture contains a non-hexadecimal digit.")
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }
}
