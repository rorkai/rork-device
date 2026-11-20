import Foundation
import XCTest

@testable import RorkDevice

final class MobileImageMounterClientTests: XCTestCase {
    func testMountReusesDevicePersonalizationManifest() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let ticket = Data([0xAA, 0xBB])
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                personalizationIdentifiersResponse(),
                [
                    "ImageSignature": ticket,
                    "Status": "Complete",
                ],
                ["Status": "ReceiveBytesAck"],
                ["Status": "Complete"],
                ["Status": "Complete"],
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0xCC])
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester,
            mountCryptex: { _ in
                XCTFail("A device with a personalized identity used the cryptex.")
                return .alreadyMounted
            }
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(
            result,
            .mounted(ticketSource: .deviceManifest)
        )
        XCTAssertEqual(result.status, .mounted)
        XCTAssertEqual(result.ticketSource, .deviceManifest)
        XCTAssertTrue(result.requiresTunnelRestart)
        XCTAssertEqual(requester.requestCount, 0)
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(
            try command(in: connection.sent[0])["Command"] as? String,
            "LookupImage"
        )
        XCTAssertEqual(
            try command(in: connection.sent[1])["Command"] as? String,
            "CopyDevices"
        )
        let manifestRequest = try command(in: connection.sent[3])
        XCTAssertEqual(
            manifestRequest["Command"] as? String,
            "QueryPersonalizationManifest"
        )
        XCTAssertEqual(
            (manifestRequest["ImageSignature"] as? Data)?.count,
            48
        )
        let receiveBytes = try command(in: connection.sent[4])
        XCTAssertEqual(
            receiveBytes["ImageSignature"] as? Data,
            ticket
        )
        XCTAssertEqual(
            connection.sent[5],
            Data("developer-image".utf8)
        )
        let mount = try command(in: connection.sent[6])
        XCTAssertEqual(mount["Command"] as? String, "MountImage")
        XCTAssertEqual(mount["ImageSignature"] as? Data, ticket)
        XCTAssertEqual(
            mount["ImageTrustCache"] as? Data,
            Data("trust-cache".utf8)
        )
        XCTAssertEqual(
            try command(in: connection.sent[7])["Command"] as? String,
            "Hangup"
        )
    }

    func testMountReportsAnImageOnlyCopyDevicesListsAsMounted()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImageSignature": [Data](),
                    "Status": "Complete",
                ],
                copyDevicesResponse(mountPaths: ["/System/Developer"]),
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0x02])
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(result, .alreadyMounted)
        XCTAssertEqual(connection.sent.count, 2)
        XCTAssertEqual(requester.requestCount, 0)
    }

    func testMountInstallsTheCryptexForADeviceTheManifestDoesNotList()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                iPhone19PersonalizationIdentifiersResponse(),
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0x02])
        )
        var cryptexMountCount = 0
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester,
            mountCryptex: { _ in
                cryptexMountCount += 1
                return .mounted(ticketSource: .appleTSS)
            }
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(result, .mounted(ticketSource: .appleTSS))
        XCTAssertEqual(cryptexMountCount, 1)
        XCTAssertEqual(requester.requestCount, 0)
        XCTAssertEqual(connection.sent.count, 3)
        XCTAssertTrue(connection.isClosed)
    }

    func testMountRejectsAnUnlistedDeviceWhenTheImageHasNoCryptexIdentity()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                iPhone19PersonalizationIdentifiersResponse(),
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: RecordingDeveloperDiskImageTicketRequester(
                ticket: Data([0x02])
            ),
            mountCryptex: { _ in
                XCTFail("An image without a Cryptex1 identity used the cryptex path.")
                return .alreadyMounted
            }
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.mount(
                PersonalizedDeveloperDiskImage(
                    contentsOf: fixture.restoreDirectory
                ),
                ecid: 123
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "The Developer Disk Image does not support board 0xA, chip 0x8160, security domain 1."
                )
            )
        }
    }

    func testMountReopensServiceAfterMissingManifestAndRequestsTicket()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let initialConnection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                personalizationIdentifiersResponse(),
            ]),
            receiveFailureAfterSendCount: 4,
            receiveFailure: .connectionClosed("Connection closed.")
        )
        let replacementConnection = FakeConnection(
            inbound: try framedMessages([
                [
                    "PersonalizationNonce": Data([0x10, 0x20]),
                    "Status": "Complete",
                ],
                ["Status": "ReceiveBytesAck"],
                ["Status": "Complete"],
                ["Status": "Complete"],
            ])
        )
        let connections = ImageMounterConnectionQueue([
            initialConnection,
            replacementConnection,
        ])
        let ticket = Data([0xDE, 0xAD])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: ticket
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(
            result,
            .mounted(ticketSource: .appleTSS)
        )
        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertEqual(requester.nonce, Data([0x10, 0x20]))
        XCTAssertEqual(requester.ecid, 123)
        XCTAssertTrue(initialConnection.isClosed)
        XCTAssertTrue(replacementConnection.isClosed)
        XCTAssertEqual(
            try command(
                in: replacementConnection.sent[0]
            )["Command"] as? String,
            "QueryNonce"
        )
        XCTAssertEqual(
            try command(
                in: replacementConnection.sent[1]
            )["ImageSignature"] as? Data,
            ticket
        )
    }

    func testMountReturnsWithoutUploadWhenImageIsAlreadyMounted()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImageSignature": [Data([0x01])],
                    "Status": "Complete",
                ],
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0x02])
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(
            result,
            .alreadyMounted
        )
        XCTAssertEqual(connection.sent.count, 1)
        XCTAssertEqual(requester.requestCount, 0)
        XCTAssertEqual(result.status, .alreadyMounted)
        XCTAssertNil(result.ticketSource)
        XCTAssertFalse(result.requiresTunnelRestart)
    }

    func testMountRequestsTicketWhenManifestQueryReturnsAnError()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let initialConnection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                personalizationIdentifiersResponse(),
                [
                    "Error": "InternalError",
                    "DetailedError": "Failed to find a cached manifest (im4m)",
                ],
            ])
        )
        let replacementConnection = FakeConnection(
            inbound: try framedMessages([
                [
                    "PersonalizationNonce": Data([0x10, 0x20]),
                    "Status": "Complete",
                ],
                ["Status": "ReceiveBytesAck"],
                ["Status": "Complete"],
                ["Status": "Complete"],
            ])
        )
        let connections = ImageMounterConnectionQueue([
            initialConnection,
            replacementConnection,
        ])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0xCC])
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            ),
            ecid: 123
        )

        XCTAssertEqual(result, .mounted(ticketSource: .appleTSS))
        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertTrue(initialConnection.isClosed)
        XCTAssertTrue(replacementConnection.isClosed)
    }

    func testMountDoesNotTreatTransportFailureAsMissingManifest()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
                copyDevicesResponse(),
                personalizationIdentifiersResponse(),
            ]),
            receiveFailureAfterSendCount: 4
        )
        let connections = ImageMounterConnectionQueue([connection])
        let requester = RecordingDeveloperDiskImageTicketRequester(
            ticket: Data([0xCC])
        )
        let mounter = PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await connections.open()
            },
            ticketRequester: requester
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.mount(
                PersonalizedDeveloperDiskImage(
                    contentsOf: fixture.restoreDirectory
                ),
                ecid: 123
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport("Injected receive failure.")
            )
        }
        XCTAssertEqual(requester.requestCount, 0)
        XCTAssertTrue(connection.isClosed)
    }

    func testUnmountSendsUnmountImageForAnImageCryptexdDidNotInstall()
        async throws
    {
        let lookup = FakeConnection(
            inbound: try framedMessages([
                copyDevicesResponse(entries: [
                    [
                        "BackingImage": "/private/var/run/mobile_image_mounter/developer.dmg",
                        "MountPath": "/System/Developer",
                    ],
                ]),
            ])
        )
        let unmount = FakeConnection(
            inbound: try framedMessages([
                ["Status": "Complete"],
            ])
        )
        let connections = ImageMounterConnectionQueue([lookup, unmount])
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            },
            uninstallCryptex: {
                XCTFail("An image cryptexd did not install went to cryptexd.")
                return true
            }
        )

        try await unmounter.unmount()

        XCTAssertTrue(lookup.isClosed)
        XCTAssertTrue(unmount.isClosed)
        XCTAssertEqual(
            try command(in: lookup.sent[0])["Command"] as? String,
            "CopyDevices"
        )
        let request = try command(in: unmount.sent[0])
        XCTAssertEqual(request["Command"] as? String, "UnmountImage")
        XCTAssertEqual(
            request["MountPath"] as? String,
            "/System/Developer"
        )
    }

    func testUnmountUninstallsTheCryptexBackingTheMountedImage()
        async throws
    {
        let lookup = FakeConnection(
            inbound: try framedMessages([
                copyDevicesResponse(entries: [cryptexDeveloperImageEntry()]),
            ])
        )
        let connections = ImageMounterConnectionQueue([lookup])
        var uninstallCount = 0
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            },
            uninstallCryptex: {
                XCTAssertTrue(lookup.isClosed)
                uninstallCount += 1
                return true
            }
        )

        try await unmounter.unmount()

        XCTAssertEqual(uninstallCount, 1)
        XCTAssertEqual(lookup.sent.count, 1)
    }

    func testUnmountUninstallsACryptexWhenNothingIsMounted() async throws {
        let lookup = FakeConnection(
            inbound: try framedMessages([copyDevicesResponse()])
        )
        let connections = ImageMounterConnectionQueue([lookup])
        var uninstallCount = 0
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            },
            uninstallCryptex: {
                uninstallCount += 1
                return true
            }
        )

        try await unmounter.unmount()

        XCTAssertEqual(uninstallCount, 1)
    }

    func testUnmountSurfacesTheDeviceErrorWhenNoImageIsMounted()
        async throws
    {
        let unmount = FakeConnection(
            inbound: try framedMessages([
                [
                    "Error": "InternalError",
                    "DetailedError": "no image mounted at path",
                ],
            ])
        )
        let connections = ImageMounterConnectionQueue([
            FakeConnection(
                inbound: try framedMessages([copyDevicesResponse()])
            ),
            unmount,
        ])
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            },
            uninstallCryptex: { false }
        )

        await XCTAssertThrowsErrorAsync({
            try await unmounter.unmount()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .lockdown(
                    "UnmountImage failed: InternalError: no image mounted at path"
                )
            )
        }
        XCTAssertTrue(unmount.isClosed)
    }

    func testUnmountSendsUnmountImageWithoutACryptexdRoute() async throws {
        let unmount = FakeConnection(
            inbound: try framedMessages([
                ["Status": "Complete"],
            ])
        )
        let connections = ImageMounterConnectionQueue([
            FakeConnection(
                inbound: try framedMessages([
                    copyDevicesResponse(entries: [cryptexDeveloperImageEntry()]),
                ])
            ),
            unmount,
        ])
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            }
        )

        try await unmounter.unmount()

        XCTAssertEqual(
            try command(in: unmount.sent[0])["Command"] as? String,
            "UnmountImage"
        )
    }

    func testUnmountRejectsResponseWithoutCompletion() async throws {
        let unmount = FakeConnection(
            inbound: try framedMessages([
                ["Status": "Busy"],
            ])
        )
        let connections = ImageMounterConnectionQueue([
            FakeConnection(
                inbound: try framedMessages([
                    copyDevicesResponse(mountPaths: ["/System/Developer"]),
                ])
            ),
            unmount,
        ])
        let unmounter = PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await connections.open()
            }
        )

        await XCTAssertThrowsErrorAsync({
            try await unmounter.unmount()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "UnmountImage response did not report completion."
                )
            )
        }
        XCTAssertTrue(unmount.isClosed)
    }

    func testListReturnsMountedImageSignatures() async throws {
        let firstSignature = Data([0x01, 0x02])
        let secondSignature = Data([0x03, 0x04])
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImageSignature": [firstSignature, secondSignature],
                    "Status": "Complete",
                ],
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let lister = PersonalizedDeveloperDiskImageLister(
            openConnection: {
                try await connections.open()
            }
        )

        let signatures = try await lister.mountedImageSignatures()

        XCTAssertEqual(signatures, [firstSignature, secondSignature])
        XCTAssertTrue(connection.isClosed)
        let request = try command(in: connection.sent[0])
        XCTAssertEqual(request["Command"] as? String, "LookupImage")
        XCTAssertEqual(request["ImageType"] as? String, "Personalized")
    }

    func testListReturnsEmptyWhenNoImageMounted() async throws {
        let connection = FakeConnection(
            inbound: try framedMessages([
                [
                    "ImagePresent": false,
                    "Status": "Complete",
                ],
            ])
        )
        let connections = ImageMounterConnectionQueue([connection])
        let lister = PersonalizedDeveloperDiskImageLister(
            openConnection: {
                try await connections.open()
            }
        )

        let signatures = try await lister.mountedImageSignatures()

        XCTAssertTrue(signatures.isEmpty)
        XCTAssertTrue(connection.isClosed)
    }
}

private final class ImageMounterConnectionQueue {
    private var connections: [FakeConnection]

    init(_ connections: [FakeConnection]) {
        self.connections = connections
    }

    func open() async throws -> DeviceConnection {
        guard !connections.isEmpty else {
            throw RorkDeviceError.transport(
                "No fake image-mounter connection remains."
            )
        }
        return connections.removeFirst()
    }
}

private final class RecordingDeveloperDiskImageTicketRequester:
    DeveloperDiskImageTicketRequesting,
    @unchecked Sendable
{
    private let ticketValue: Data
    private(set) var requestCount = 0
    private(set) var nonce: Data?
    private(set) var ecid: UInt64?

    init(ticket: Data) {
        ticketValue = ticket
    }

    func ticket(
        for _: DeveloperDiskImageBuildIdentity,
        identifiers _: PersonalizationIdentifiers,
        nonce: Data,
        ecid: UInt64
    ) async throws -> Data {
        requestCount += 1
        self.nonce = nonce
        self.ecid = ecid
        return ticketValue
    }
}

private func copyDevicesResponse(
    mountPaths: [String] = []
) -> [String: Any] {
    copyDevicesResponse(entries: mountPaths.map { ["MountPath": $0] })
}

private func copyDevicesResponse(entries: [[String: Any]]) -> [String: Any] {
    [
        "EntryList": entries,
        "Status": "Complete",
    ]
}

/// The `/System/Developer` entry `CopyDevices` listed for a cryptexd-installed
/// Developer Disk Image on an iPhone19,2 with iOS 27.2.1 (2026-11-20).
private func cryptexDeveloperImageEntry() -> [String: Any] {
    [
        "BackingImage": "/private/var/db/com.apple.security.cryptexd/codex.system/cryptex/com.apple.MobileAsset.DDI/gdmg",
        "DeviceType": "DiskImage",
        "DiskImageType": "Personalized",
        "IsMounted": true,
        "MountPath": "/System/Developer",
        "PersonalizedImageType": "DeveloperDiskImage",
    ]
}

/// Identifiers an iPhone19,2 reported on 2026-11-20, absent from Xcode 27's
/// personalized identities.
private func iPhone19PersonalizationIdentifiersResponse() -> [String: Any] {
    [
        "PersonalizationIdentifiers": [
            "BoardId": 10,
            "ChipID": 0x8160,
            "SecurityDomain": 1,
        ],
    ]
}

private func personalizationIdentifiersResponse() -> [String: Any] {
    [
        "PersonalizationIdentifiers": [
            "BoardId": 12,
            "ChipID": 0x8150,
            "SecurityDomain": 1,
            "Ap,ProductType": "iPhone18,1",
        ],
        "Status": "Complete",
    ]
}

private func framedMessages(
    _ messages: [[String: Any]]
) throws -> Data {
    try messages.reduce(into: Data()) {
        $0.append(try PropertyListMessageFramer.encode($1))
    }
}

private func command(in data: Data) throws -> [String: Any] {
    guard data.count >= 4 else {
        throw RorkDeviceError.protocolViolation(
            "Captured data is not a framed property list."
        )
    }
    return try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: data.dropFirst(4),
            options: [],
            format: nil
        ) as? [String: Any]
    )
}
