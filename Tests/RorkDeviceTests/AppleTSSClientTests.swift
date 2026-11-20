import Foundation
import XCTest

@testable import RorkDevice

final class AppleTSSClientTests: XCTestCase {
    func testRequestIncludesHardwareValuesAndAppliesRestoreRules() throws {
        let buildIdentity = DeveloperDiskImageBuildIdentity(
            boardID: 12,
            chipID: 0x8150,
            securityDomain: 1,
            propertyList: [:],
            manifestEntries: [
                "PersonalizedDMG": [
                    "Digest": Data(repeating: 0x11, count: 48),
                    "Info": [
                        "Path": "DeveloperDiskImage.dmg",
                    ],
                    "Name": "DeveloperDiskImage",
                    "Trusted": true,
                ],
                "LoadableTrustCache": [
                    "Digest": Data(repeating: 0x22, count: 48),
                    "Info": [
                        "Path": "Firmware/DeveloperDiskImage.dmg.trustcache",
                        "RestoreRequestRules": [
                            [
                                "Actions": ["EPRO": true],
                                "Conditions": [
                                    "ApCurrentProductionMode": true,
                                    "ApRequiresImage4": true,
                                ],
                            ],
                            [
                                "Actions": ["ESEC": true],
                                "Conditions": [
                                    "ApRawSecurityMode": true,
                                    "ApRequiresImage4": true,
                                ],
                            ],
                        ],
                    ],
                    "Trusted": true,
                ],
            ]
        )
        let identifiers = PersonalizationIdentifiers(
            boardID: 12,
            chipID: 0x8150,
            securityDomain: 1,
            additionalTSSParameters: [
                "Ap,ProductType": "iPhone18,1",
                "Ignored": "value",
            ]
        )

        let request = try AppleTSSRequest(
            buildIdentity: buildIdentity,
            identifiers: identifiers,
            nonce: Data([0x01, 0x02]),
            ecid: 123,
            requestIdentifier: UUID(
                uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
            )!
        ).propertyList

        XCTAssertEqual(request["@ApImg4Ticket"] as? Bool, true)
        XCTAssertEqual(request["@BBTicket"] as? Bool, true)
        XCTAssertEqual(request["@HostPlatformInfo"] as? String, "mac")
        XCTAssertEqual(
            request["@UUID"] as? String,
            "00112233-4455-6677-8899-AABBCCDDEEFF"
        )
        XCTAssertEqual(request["ApBoardID"] as? UInt64, 12)
        XCTAssertEqual(request["ApChipID"] as? UInt64, 0x8150)
        XCTAssertEqual(request["ApSecurityDomain"] as? UInt64, 1)
        XCTAssertEqual(request["ApECID"] as? UInt64, 123)
        XCTAssertEqual(request["ApNonce"] as? Data, Data([0x01, 0x02]))
        XCTAssertEqual(request["Ap,ProductType"] as? String, "iPhone18,1")
        XCTAssertNil(request["Ignored"])
        XCTAssertEqual((request["SepNonce"] as? Data)?.count, 20)

        let image = try XCTUnwrap(
            request["PersonalizedDMG"] as? [String: Any]
        )
        XCTAssertEqual(image["Name"] as? String, "DeveloperDiskImage")
        XCTAssertEqual(image["EPRO"] as? Bool, true)
        XCTAssertEqual(image["ESEC"] as? Bool, true)
        XCTAssertNil(image["Info"])

        let trustCache = try XCTUnwrap(
            request["LoadableTrustCache"] as? [String: Any]
        )
        XCTAssertEqual(trustCache["EPRO"] as? Bool, true)
        XCTAssertEqual(trustCache["ESEC"] as? Bool, true)
        XCTAssertNil(trustCache["Info"])
    }

    func testResponseParsesRawRequestStringPlist() throws {
        let ticket = Data([0xAA, 0xBB, 0xCC])
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["ApImg4Ticket": ticket],
            format: .xml,
            options: 0
        )
        var response = Data("STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".utf8)
        response.append(plist)

        XCTAssertEqual(
            try AppleTSSResponse(data: response).ticket,
            ticket
        )
    }

    func testResponsePreservesServerFailureMessage() throws {
        let response = Data(
            "STATUS=94&MESSAGE=This device is not eligible".utf8
        )

        XCTAssertThrowsError(try AppleTSSResponse(data: response)) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Apple TSS rejected the request with status 94: This device is not eligible"
                )
            )
        }
    }

    func testClientPostsXMLToStrictHTTPSTransport() async throws {
        let ticket = Data([0x01, 0x02, 0x03])
        let responsePlist = try PropertyListSerialization.data(
            fromPropertyList: ["ApImg4Ticket": ticket],
            format: .xml,
            options: 0
        )
        var responseData = Data(
            "STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".utf8
        )
        responseData.append(responsePlist)
        let transport = RecordingTSSHTTPTransport(
            response: TSSHTTPResponse(
                statusCode: 200,
                body: responseData
            )
        )
        let client = AppleTSSClient(transport: transport)

        let result = try await client.ticket(
            for: DeveloperDiskImageBuildIdentity(
                boardID: 12,
                chipID: 0x8150,
                securityDomain: 1,
                propertyList: [:],
                manifestEntries: [:]
            ),
            identifiers: PersonalizationIdentifiers(
                boardID: 12,
                chipID: 0x8150,
                securityDomain: 1,
                additionalTSSParameters: [:]
            ),
            nonce: Data([0x04]),
            ecid: 123
        )

        XCTAssertEqual(result, ticket)
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url.scheme, "https")
        XCTAssertEqual(request.url.host, "gs.apple.com")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.headers["Content-Type"],
            "text/xml; charset=utf-8"
        )
        XCTAssertFalse(request.body.isEmpty)
    }

    func testCryptexRequestIdentifiesTheDeviceByItsCryptexUDID() throws {
        let nonce = Data(repeating: 0xE5, count: 48)
        let payload = CryptexDeveloperDiskImagePayload(
            imageURL: URL(fileURLWithPath: "/cryptex.dmg"),
            volumeHashURL: URL(fileURLWithPath: "/cryptex.dmg.root_hash"),
            infoURL: URL(fileURLWithPath: "/cryptex.dmg.cryptex_info"),
            trustCacheURL: URL(fileURLWithPath: "/cryptex.dmg.trustcache"),
            personalizedDigests: [
                "Cryptex1,GenericVolume": Data(repeating: 0x11, count: 48),
            ],
            nonceDomain: 4,
            subType: 2,
            usesProductClass: true,
            version: "39.999.999.0.0,0",
            preauthorizationVersion: "39.999.999.0.0,0"
        )
        // The chip and ECID layout matches the `Cryptex1,UDID` in the ticket
        // Apple issued for an iPhone19,2 with iOS 27.2.1 (2026-11-20). The
        // ECID here is made up.
        let identifiers = CryptexPersonalizationIdentifiers(
            chipID: 0x8160,
            ecid: 0x0012_3456_78AB_CDEF,
            cryptexChipID: 0xFF10,
            cryptexType: 3,
            productClass: 0xF2,
            isProductionMode: true,
            isSecureMode: true
        )

        let request = CryptexTSSRequest(
            payload: payload,
            identifiers: identifiers,
            nonce: nonce
        ).propertyList

        XCTAssertEqual(
            request["Cryptex1,UDID"] as? Data,
            Data(hexFixture: "00000000000081600012345678abcdef")
        )
        XCTAssertEqual(request["@Cryptex1,Ticket"] as? Bool, true)
        XCTAssertEqual(request["Cryptex1,Nonce"] as? Data, nonce)
        XCTAssertEqual(request["Cryptex1,NonceDomain"] as? UInt64, 4)
        XCTAssertEqual(request["Cryptex1,ChipID"] as? UInt64, 0xFF10)
        XCTAssertEqual(request["Cryptex1,ProductClass"] as? UInt64, 0xF2)
        XCTAssertEqual(request["Cryptex1,Type"] as? UInt64, 3)
        XCTAssertEqual(request["Cryptex1,SubType"] as? UInt64, 2)
        XCTAssertEqual(request["Cryptex1,UseProductClass"] as? Bool, true)
        XCTAssertEqual(request["Cryptex1,ProductionMode"] as? Bool, true)
        XCTAssertEqual(request["ApSecurityMode"] as? Bool, true)
        XCTAssertEqual(request["Cryptex1,UniqueTagList"] as? Data, Data())
        XCTAssertEqual(
            (request["Cryptex1,GenericVolume"] as? [String: Any])?["Digest"]
                as? Data,
            Data(repeating: 0x11, count: 48)
        )
        for key in [
            "@ApImg4Ticket", "ApECID", "ApChipID", "ApBoardID",
            "ApNonce", "SepNonce", "Cryptex1,GenericDmg",
        ] {
            XCTAssertNil(request[key], key)
        }
        XCTAssertNoThrow(try PropertyListCodec.encode(request))
    }

    func testCryptexTicketIsReadFromItsOwnResponseKey() throws {
        let ticket = Data([0x30, 0x82])
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Cryptex1,Ticket": ticket],
            format: .xml,
            options: 0
        )
        var response = Data("STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".utf8)
        response.append(plist)

        XCTAssertEqual(
            try AppleTSSResponse(
                data: response,
                ticketKey: "Cryptex1,Ticket"
            ).ticket,
            ticket
        )
        XCTAssertThrowsError(try AppleTSSResponse(data: response))
    }

    func testClientRejectsNonSuccessfulHTTPStatus() async throws {
        let transport = RecordingTSSHTTPTransport(
            response: TSSHTTPResponse(
                statusCode: 503,
                body: Data("unavailable".utf8)
            )
        )
        let client = AppleTSSClient(transport: transport)

        await XCTAssertThrowsErrorAsync(
            {
                try await client.ticket(
                    for: DeveloperDiskImageBuildIdentity(
                        boardID: 12,
                        chipID: 0x8150,
                        securityDomain: 1,
                        propertyList: [:],
                        manifestEntries: [:]
                    ),
                    identifiers: PersonalizationIdentifiers(
                        boardID: 12,
                        chipID: 0x8150,
                        securityDomain: 1,
                        additionalTSSParameters: [:]
                    ),
                    nonce: Data([0x04]),
                    ecid: 123
                )
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .transport(
                        "Apple TSS returned HTTP status 503."
                    )
                )
            }
        )
    }
}

private final class RecordingTSSHTTPTransport:
    TSSHTTPTransport,
    @unchecked Sendable
{
    private let response: TSSHTTPResponse
    private(set) var request: TSSHTTPRequest?

    init(response: TSSHTTPResponse) {
        self.response = response
    }

    func response(
        for request: TSSHTTPRequest
    ) async throws -> TSSHTTPResponse {
        self.request = request
        return response
    }
}

extension Data {
    /// Decodes an even-length hexadecimal fixture string, stopping the test
    /// run on a malformed fixture.
    init(hexFixture hexadecimal: String) {
        precondition(
            hexadecimal.count.isMultiple(of: 2),
            "Hex fixture has an odd number of digits."
        )
        var bytes: [UInt8] = []
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                preconditionFailure(
                    "Hex fixture has a non-hex pair \(hexadecimal[index..<next])."
                )
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
