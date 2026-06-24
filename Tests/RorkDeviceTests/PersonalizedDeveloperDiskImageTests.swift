import Crypto
import Foundation
import XCTest

@testable import RorkDevice

final class PersonalizedDeveloperDiskImageTests: XCTestCase {
    func testPayloadSelectsMatchingHardwareIdentityAndVerifiesFiles() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        let payload = try image.payload(
            matching: PersonalizationIdentifiers(
                boardID: 12,
                chipID: 0x8150,
                securityDomain: 1,
                additionalValues: [:]
            )
        )

        XCTAssertEqual(payload.imageURL.lastPathComponent, "DeveloperDiskImage.dmg")
        XCTAssertEqual(payload.trustCacheURL.lastPathComponent, "DeveloperDiskImage.dmg.trustcache")
        XCTAssertEqual(payload.identity.boardID, 12)
        XCTAssertEqual(payload.identity.chipID, 0x8150)
        XCTAssertEqual(payload.identity.securityDomain, 1)
    }

    func testPayloadRejectsIdentityForAnotherSecurityDomain() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x02"
        )
        defer { fixture.remove() }
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        XCTAssertThrowsError(
            try image.payload(
                matching: PersonalizationIdentifiers(
                    boardID: 12,
                    chipID: 0x8150,
                    securityDomain: 1,
                    additionalValues: [:]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "The Developer Disk Image does not support board 0xC, chip 0x8150, security domain 1."
                )
            )
        }
    }

    func testPayloadRejectsManifestPathOutsideRestoreDirectory() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            imagePath: "../DeveloperDiskImage.dmg"
        )
        defer { fixture.remove() }
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        XCTAssertThrowsError(
            try image.payload(
                matching: PersonalizationIdentifiers(
                    boardID: 12,
                    chipID: 0x8150,
                    securityDomain: 1,
                    additionalValues: [:]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image manifest path escapes the Restore directory: ../DeveloperDiskImage.dmg"
                )
            )
        }
    }

    func testPayloadRejectsFileWhoseSHA384DoesNotMatchManifest() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        try Data("tampered".utf8).write(
            to: fixture.restoreDirectory.appendingPathComponent(
                "DeveloperDiskImage.dmg"
            )
        )
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        XCTAssertThrowsError(
            try image.payload(
                matching: PersonalizationIdentifiers(
                    boardID: 12,
                    chipID: 0x8150,
                    securityDomain: 1,
                    additionalValues: [:]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image digest does not match BuildManifest.plist."
                )
            )
        }
    }
}

struct ImageFixture {
    let directory: URL
    let restoreDirectory: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeImageFixture(
    boardID: String,
    chipID: String,
    securityDomain: String,
    imagePath: String = "DeveloperDiskImage.dmg"
) throws -> ImageFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let restoreDirectory = directory.appendingPathComponent(
        "Restore",
        isDirectory: true
    )
    let firmwareDirectory = restoreDirectory.appendingPathComponent(
        "Firmware",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: firmwareDirectory,
        withIntermediateDirectories: true
    )
    let imageData = Data("developer-image".utf8)
    let trustCacheData = Data("trust-cache".utf8)
    try imageData.write(
        to: restoreDirectory.appendingPathComponent(
            "DeveloperDiskImage.dmg"
        )
    )
    try trustCacheData.write(
        to: firmwareDirectory.appendingPathComponent(
            "DeveloperDiskImage.dmg.trustcache"
        )
    )
    let manifest: [String: Any] = [
        "BuildIdentities": [
            [
                "ApBoardID": boardID,
                "ApChipID": chipID,
                "ApSecurityDomain": securityDomain,
                "Manifest": [
                    "PersonalizedDMG": [
                        "Digest": Data(SHA384.hash(data: imageData)),
                        "Info": [
                            "Path": imagePath,
                        ],
                        "Name": "DeveloperDiskImage",
                        "Trusted": true,
                    ],
                    "LoadableTrustCache": [
                        "Digest": Data(SHA384.hash(data: trustCacheData)),
                        "Info": [
                            "Path": "Firmware/DeveloperDiskImage.dmg.trustcache",
                        ],
                        "Trusted": true,
                    ],
                ],
            ],
        ],
    ]
    let manifestData = try PropertyListSerialization.data(
        fromPropertyList: manifest,
        format: .xml,
        options: 0
    )
    try manifestData.write(
        to: restoreDirectory.appendingPathComponent("BuildManifest.plist")
    )
    return ImageFixture(
        directory: directory,
        restoreDirectory: restoreDirectory
    )
}
