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
                additionalTSSParameters: [:]
            )
        )

        XCTAssertEqual(payload.imageURL.lastPathComponent, "DeveloperDiskImage.dmg")
        XCTAssertEqual(payload.trustCacheURL.lastPathComponent, "DeveloperDiskImage.dmg.trustcache")
        XCTAssertEqual(payload.buildIdentity.boardID, 12)
        XCTAssertEqual(payload.buildIdentity.chipID, 0x8150)
        XCTAssertEqual(payload.buildIdentity.securityDomain, 1)
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
                    additionalTSSParameters: [:]
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
                    additionalTSSParameters: [:]
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
                    additionalTSSParameters: [:]
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

    func testCryptexPayloadSelectsTheIdentityForTheDeviceAndDigestsPersonalizedFiles() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        let payload = try image.cryptexPayload(
            matching: iPhone19CryptexIdentifiers
        )

        XCTAssertTrue(image.hasCryptexIdentity)
        XCTAssertFalse(
            image.hasPersonalizedIdentity(
                matching: PersonalizationIdentifiers(
                    boardID: 0x0A,
                    chipID: 0x8160,
                    securityDomain: 1,
                    additionalTSSParameters: [:]
                )
            )
        )
        XCTAssertEqual(payload.imageURL.lastPathComponent, "cryptex.dmg")
        XCTAssertEqual(payload.nonceDomain, 4)
        XCTAssertEqual(payload.subType, 2)
        XCTAssertTrue(payload.usesProductClass)
        XCTAssertEqual(payload.version, "39.999.999.0.0,0")
        XCTAssertEqual(
            payload.preauthorizationVersion,
            "39.999.999.0.0,0"
        )
        XCTAssertEqual(
            payload.personalizedDigests,
            [
                "Cryptex1,GenericVolume": Data(
                    SHA384.hash(data: CryptexFixtureFile.volumeHash)
                ),
                "Cryptex1,CryptexInfoPlist": Data(
                    SHA384.hash(data: CryptexFixtureFile.info)
                ),
                "Cryptex1,GenericTrustCache": Data(
                    SHA384.hash(data: CryptexFixtureFile.trustCache)
                ),
            ]
        )
    }

    func testCryptexPayloadRejectsAnotherProductClass() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )
        let identifiers = CryptexPersonalizationIdentifiers(
            chipID: 0x8160,
            ecid: 1,
            cryptexChipID: 0xFF10,
            cryptexType: 3,
            productClass: 0xF3,
            isProductionMode: true,
            isSecureMode: true
        )

        XCTAssertThrowsError(
            try image.cryptexPayload(matching: identifiers)
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "The Developer Disk Image has no Cryptex1 identity for chip 0xFF10, type 3, product class 0xF3."
                )
            )
        }
    }

    func testCryptexPayloadRejectsAModifiedFile() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        try Data("modified".utf8).write(
            to: fixture.restoreDirectory.appendingPathComponent(
                "Firmware/cryptex.dmg.trustcache"
            )
        )
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: fixture.restoreDirectory
        )

        XCTAssertThrowsError(
            try image.cryptexPayload(matching: iPhone19CryptexIdentifiers)
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image Cryptex1,GenericTrustCache digest does not match BuildManifest.plist."
                )
            )
        }
    }

    func testImageWithoutCryptexIdentityReportsNone() throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }

        XCTAssertFalse(
            try PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ).hasCryptexIdentity
        )
    }
}

struct ImageFixture {
    let directory: URL
    let restoreDirectory: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Contents of the Cryptex1 identity files `makeImageFixture` writes.
enum CryptexFixtureFile {
    static let image = Data(repeating: 0x63, count: 70_000)
    static let volumeHash = Data("root hash".utf8)
    static let info = Data("cryptex info".utf8)
    static let trustCache = Data("cryptex trust cache".utf8)
}

func makeImageFixture(
    boardID: String,
    chipID: String,
    securityDomain: String,
    imagePath: String = "DeveloperDiskImage.dmg",
    includesCryptexIdentity: Bool = false
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
    var buildIdentities: [[String: Any]] = [
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
        ]
    if includesCryptexIdentity {
        buildIdentities.append(
            try makeCryptexIdentity(in: restoreDirectory)
        )
    }
    let manifest: [String: Any] = ["BuildIdentities": buildIdentities]
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

/// Writes the Cryptex1 files and returns an identity shaped like Xcode 27's.
private func makeCryptexIdentity(
    in restoreDirectory: URL
) throws -> [String: Any] {
    let files: [(key: String, path: String, data: Data, personalize: Bool)] = [
        ("Cryptex1,GenericDmg", "cryptex.dmg", CryptexFixtureFile.image, false),
        (
            "Cryptex1,GenericVolume",
            "Firmware/cryptex.dmg.root_hash",
            CryptexFixtureFile.volumeHash,
            true
        ),
        (
            "Cryptex1,CryptexInfoPlist",
            "Firmware/cryptex.dmg.cryptex_info",
            CryptexFixtureFile.info,
            true
        ),
        (
            "Cryptex1,GenericTrustCache",
            "Firmware/cryptex.dmg.trustcache",
            CryptexFixtureFile.trustCache,
            true
        ),
    ]
    var manifest: [String: Any] = [:]
    for file in files {
        try file.data.write(
            to: restoreDirectory.appendingPathComponent(file.path)
        )
        manifest[file.key] = [
            "Digest": Data(SHA384.hash(data: file.data)),
            "Info": [
                "Path": file.path,
                "Personalize": file.personalize,
            ],
        ]
    }
    return [
        "Ap,TargetType": "ioscryptex",
        "Cryptex1,ChipID": "0xFF10",
        "Cryptex1,NonceDomain": 4,
        "Cryptex1,PreauthorizationVersion": "39.999.999.0.0,0",
        "Cryptex1,ProductClass": "0xF2",
        "Cryptex1,SubType": 2,
        "Cryptex1,Type": 3,
        "Cryptex1,UseProductClass": true,
        "Cryptex1,Version": "39.999.999.0.0,0",
        "Manifest": manifest,
    ]
}

/// cryptexd identifiers of an iPhone19,2, as read on 2026-11-20.
let iPhone19CryptexIdentifiers = CryptexPersonalizationIdentifiers(
    chipID: 0x8160,
    ecid: 7_434_683_448_033_290,
    cryptexChipID: 0xFF10,
    cryptexType: 3,
    productClass: 0xF2,
    isProductionMode: true,
    isSecureMode: true
)
