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
