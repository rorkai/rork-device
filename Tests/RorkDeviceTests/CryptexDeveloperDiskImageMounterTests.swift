import Foundation
import XCTest

@testable import RorkDevice

final class CryptexDeveloperDiskImageMounterTests: XCTestCase {
    func testMountInstallsTheCryptexWithAnAppleTicket() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let ticket = Data(repeating: 0x7A, count: 300)
        let install = try cryptexdConnection(
            replyingWith: [
                "argv": .dictionary([
                    "remote-cryptex": .dictionary([
                        "remote-cryptex-identifier": .string(
                            "com.apple.MobileAsset.DDI"
                        ),
                        "remote-cryptex-version": .string("27.2.52.0"),
                    ]),
                ]),
            ],
            after: try installStreamTraffic()
        )
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(sampleChipProperties),
            ]),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(["remote-cryptex-array": .array([])]),
            ]),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(["nonce": .data(sampleSerializedNonce)]),
            ]),
            install,
        ])
        let requester = RecordingCryptexTicketRequester(ticket: ticket)
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: requester
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            )
        )

        XCTAssertEqual(result, .mounted(ticketSource: .appleTSS))
        XCTAssertTrue(result.requiresTunnelRestart)
        XCTAssertEqual(
            try connections.opened.map { try routine(sentOn: $0).name },
            [
                "read-personalization-id", "copy-installed", "get-nonce",
                "install",
            ]
        )
        XCTAssertTrue(connections.opened.allSatisfy(\.isClosed))
        XCTAssertEqual(
            try routine(sentOn: connections.connection(2)).argv,
            ["nonce-domain-handle": .uint64(4)]
        )
        XCTAssertEqual(requester.nonce, sampleNonce)
        XCTAssertEqual(
            requester.identifiers,
            CryptexPersonalizationIdentifiers(
                chipID: 0x8160,
                ecid: 0x0012_3456_78AB_CDEF,
                cryptexChipID: 0xFF10,
                cryptexType: 3,
                productClass: 0xF2,
                isProductionMode: true,
                isSecureMode: true
            )
        )

        let argv = try routine(sentOn: install).argv
        XCTAssertEqual(argv["image-type-index"], .int64(10))
        XCTAssertEqual(argv["persistence"], .uint64(2))
        XCTAssertEqual(argv["nonce-persistence"], .uint64(1))
        XCTAssertEqual(argv["client-version"], .uint64(3))
        XCTAssertEqual(
            argv["cryptex1-properties"],
            .dictionary([
                "Cryptex1,NonceDomain": .uint64(4),
                "Cryptex1,PreauthVersion": .string("39.999.999.0.0,0"),
                "Cryptex1,SubType": .uint64(2),
                "Cryptex1,UseProductClass": .bool(true),
                "Cryptex1,Version": .string("39.999.999.0.0,0"),
                "MountedCryptex": .bool(false),
            ])
        )
        let uploads = try uploadedPayloads(on: install)
        let expected: [(String, Data)] = [
            ("image", CryptexFixtureFile.image),
            ("volumehash", CryptexFixtureFile.volumeHash),
            ("info", CryptexFixtureFile.info),
            ("trustcache", CryptexFixtureFile.trustCache),
            ("im4m", ticket),
        ]
        for (argument, data) in expected {
            guard case let .fileTransfer(identifier, size)? = argv[argument]
            else {
                return XCTFail("\(argument) is not a file transfer.")
            }
            XCTAssertEqual(size, UInt64(data.count), argument)
            XCTAssertEqual(uploads[identifier], data, argument)
        }
    }

    func testMountReplacesADeveloperDiskImageCryptexThatIsNotMounted()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(sampleChipProperties),
            ]),
            try cryptexdConnection(replyingWith: installedReply([
                developerDiskImageCryptex,
            ])),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary([:]),
                "error": .uint64(0),
            ]),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(["nonce": .data(sampleSerializedNonce)]),
            ]),
            try cryptexdConnection(
                replyingWith: ["argv": .dictionary([:])],
                after: try installStreamTraffic()
            ),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        let result = try await mounter.mount(
            PersonalizedDeveloperDiskImage(
                contentsOf: fixture.restoreDirectory
            )
        )

        XCTAssertEqual(result, .mounted(ticketSource: .appleTSS))
        XCTAssertEqual(
            try connections.opened.map { try routine(sentOn: $0).name },
            [
                "read-personalization-id", "copy-installed", "uninstall",
                "get-nonce", "install",
            ]
        )
        XCTAssertEqual(
            try routine(sentOn: connections.connection(2)).argv,
            developerDiskImageUninstallArgv
        )
    }

    func testUninstallRemovesOnlyTheDeveloperDiskImageCryptex() async throws {
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: installedReply([
                .dictionary([
                    "remote-cryptex-identifier": .string("com.example.other"),
                    "remote-cryptex-version": .string("1.0"),
                ]),
                developerDiskImageCryptex,
            ])),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary([:]),
                "error": .uint64(0),
            ]),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        let uninstalled = try await mounter.uninstall()

        XCTAssertTrue(uninstalled)
        XCTAssertEqual(
            try connections.opened.map { try routine(sentOn: $0).name },
            ["copy-installed", "uninstall"]
        )
        XCTAssertEqual(
            try routine(sentOn: connections.connection(1)).argv,
            developerDiskImageUninstallArgv
        )
        XCTAssertTrue(connections.opened.allSatisfy(\.isClosed))
    }

    func testUninstallReportsThatNoDeveloperDiskImageCryptexIsInstalled()
        async throws
    {
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: installedReply([])),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        let uninstalled = try await mounter.uninstall()

        XCTAssertFalse(uninstalled)
        XCTAssertEqual(connections.opened.count, 1)
    }

    func testUninstallSurfacesACryptexdRefusal() async throws {
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: installedReply([
                developerDiskImageCryptex,
            ])),
            try cryptexdConnection(replyingWith: ["error": .uint64(2)]),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.uninstall()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .cryptexd("uninstall failed with errno 2.")
            )
        }
    }

    func testMountKeepsTheInstalledCryptexWhenTheImageCannotReplaceIt()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        var otherChip = sampleChipProperties
        otherChip["img4_chip_fchp"] = .uint64(0xFF11)
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(otherChip),
            ]),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.mount(
                PersonalizedDeveloperDiskImage(
                    contentsOf: fixture.restoreDirectory
                )
            )
        }) { error in
            XCTAssertNotNil(error as? RorkDeviceError)
        }
        XCTAssertEqual(
            try connections.opened.map { try routine(sentOn: $0).name },
            ["read-personalization-id"]
        )
    }

    func testUninstallFindsNothingWhenCryptexdIsNotAdvertised() async throws {
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: {
                throw RorkDeviceError.serviceNotAdvertised(
                    CryptexDeveloperDiskImageMounter.serviceName
                )
            },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        let uninstalled = try await mounter.uninstall()

        XCTAssertFalse(uninstalled)
    }

    func testRoutineWaitsForControlStreamCredit() async throws {
        var settings = Data()
        settings.appendBigEndian(UInt16(0x4))
        settings.appendBigEndian(UInt32(0))
        var inbound = remoteXPCTestFrame(
            type: 0x04,
            streamIdentifier: 0,
            payload: settings
        )
        inbound.append(
            try remoteXPCSessionHandshakeInbound().dropFirst(9)
        )
        let connection = FakeConnection(inbound: inbound)
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { connection },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.uninstall()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport("Fake connection underflow.")
            )
        }
        let requests = try sentFrames(connection.sent.filter { $0.count >= 9 })
            .filter { $0.type == 0x00 && $0.streamIdentifier == 1 }
            .compactMap {
                try RemoteXPCMessageCodec.decodeFirstMessage(from: $0.payload)?
                    .message
            }
            .filter { $0.messageIdentifier == 1 }
        XCTAssertTrue(requests.isEmpty)
    }

    func testUninstallRejectsAMalformedErrorStatus() async throws {
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: installedReply([
                developerDiskImageCryptex,
            ])),
            try cryptexdConnection(replyingWith: ["error": .string("ok")]),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.uninstall()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "cryptexd answered uninstall with a malformed error status \(String(describing: RemoteXPCValue.string("ok")))."
                )
            )
        }
    }

    func testMountSurfacesAnInstallRefusalSentBeforeAnyUpload() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let install = try cryptexdConnection(replyingWith: [
            "cferr": .string("ticket rejected"),
        ])
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(sampleChipProperties),
            ]),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(["remote-cryptex-array": .array([])]),
            ]),
            try cryptexdConnection(replyingWith: [
                "argv": .dictionary(["nonce": .data(sampleSerializedNonce)]),
            ]),
            install,
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.mount(
                PersonalizedDeveloperDiskImage(
                    contentsOf: fixture.restoreDirectory
                )
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .cryptexd("install failed: \(String(describing: RemoteXPCValue.string("ticket rejected")))")
            )
        }
        XCTAssertTrue(install.isClosed)
        XCTAssertTrue(try uploadedPayloads(on: install).values.allSatisfy(\.isEmpty))
    }

    func testMountSurfacesACryptexdRefusal() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01",
            includesCryptexIdentity: true
        )
        defer { fixture.remove() }
        let connections = CryptexdConnectionQueue([
            try cryptexdConnection(replyingWith: ["error": .uint64(1)]),
        ])
        let mounter = CryptexDeveloperDiskImageMounter(
            openConnection: { try await connections.open() },
            ticketRequester: RecordingCryptexTicketRequester(ticket: Data([1]))
        )

        await XCTAssertThrowsErrorAsync({
            try await mounter.mount(
                PersonalizedDeveloperDiskImage(
                    contentsOf: fixture.restoreDirectory
                )
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .cryptexd("read-personalization-id failed with errno 1.")
            )
            XCTAssertEqual(RorkDeviceFailure(error).code, .cryptexd)
        }
    }

    func testImg4NonceReturnsTheBytesItsLengthNames() throws {
        XCTAssertEqual(try img4Nonce(from: sampleSerializedNonce), sampleNonce)
        XCTAssertThrowsError(
            try img4Nonce(from: sampleSerializedNonce.prefix(40))
        )
        var invalidLength = sampleSerializedNonce
        invalidLength[52] = 49
        XCTAssertThrowsError(try img4Nonce(from: invalidLength))
    }
}

/// The Developer Disk Image entry of a `copy-installed` reply from an
/// iPhone19,2 with iOS 27.2.1 (2026-11-20).
private let developerDiskImageCryptex = RemoteXPCValue.dictionary([
    "remote-cryptex-identifier": .string("com.apple.MobileAsset.DDI"),
    "remote-cryptex-version": .string("27.2.52.0"),
])

/// The `argv` that uninstalls `developerDiskImageCryptex`.
private let developerDiskImageUninstallArgv: [String: RemoteXPCValue] = [
    "client-version": .uint64(3),
    "remote-cryptex-identifier": .string("com.apple.MobileAsset.DDI"),
    "remote-cryptex-version": .string("27.2.52.0"),
]

/// Builds a `copy-installed` reply listing `cryptexes`.
private func installedReply(
    _ cryptexes: [RemoteXPCValue]
) -> [String: RemoteXPCValue] {
    [
        "argv": .dictionary(["remote-cryptex-array": .array(cryptexes)]),
        "error": .uint64(0),
    ]
}

/// A serialized `img4_nonce_t` laid out like the 56-byte `get-nonce` reply
/// of an iPhone19,2 with iOS 27.2.1 (2026-11-20), with a made-up nonce.
private let sampleSerializedNonce = Data(
    hexFixture: "00005a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a000030000000"
)
private let sampleNonce = Data(
    hexFixture: "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"
)

/// Chip properties shaped like the `read-personalization-id` reply of an
/// iPhone19,2 with iOS 27.2.1 (2026-11-20), with a made-up ECID.
private let sampleChipProperties: [String: RemoteXPCValue] = [
    "img4_chip_bord": .uint64(0x0A),
    "img4_chip_chip": .uint64(0x8160),
    "img4_chip_clas": .uint64(0xF2),
    "img4_chip_cpro": .uint64(1),
    "img4_chip_csec": .uint64(1),
    "img4_chip_ecid": .uint64(0x0012_3456_78AB_CDEF),
    "img4_chip_fchp": .uint64(0xFF10),
    "img4_chip_type": .uint64(3),
]

/// Builds a cryptexd connection that completes the RemoteXPC handshake,
/// delivers `traffic`, then answers one routine on the reply stream.
private func cryptexdConnection(
    replyingWith reply: [String: RemoteXPCValue],
    after traffic: Data = Data()
) throws -> FakeConnection {
    var inbound = try remoteXPCSessionHandshakeInbound()
    inbound.append(traffic)
    inbound.append(
        remoteXPCTestFrame(
            type: 0x00,
            streamIdentifier: 3,
            payload: try RemoteXPCMessageCodec.encode(
                value: .dictionary(reply),
                flags: 0x00020101,
                messageIdentifier: 1
            )
        )
    )
    return FakeConnection(inbound: inbound)
}

/// Accepts the five install transfers and opens the windows the image needs.
private func installStreamTraffic() throws -> Data {
    var traffic = Data()
    for (index, stream) in [UInt32(5), 7, 9, 11, 13].enumerated() {
        traffic.append(
            try fileOpenReply(identifier: UInt64(index) + 2, on: stream)
        )
    }
    for stream: UInt32 in [0, 5] {
        var increment = Data()
        increment.appendBigEndian(UInt32(1_000_000))
        traffic.append(
            remoteXPCTestFrame(
                type: 0x08,
                streamIdentifier: stream,
                payload: increment
            )
        )
    }
    return traffic
}

/// Decodes the routine request a cryptexd connection carried.
private func routine(
    sentOn connection: FakeConnection
) throws -> (name: String?, argv: [String: RemoteXPCValue]) {
    let request = try sentFrames(connection.sent.filter { $0.count >= 9 })
        .filter { $0.type == 0x00 && $0.streamIdentifier == 1 }
        .compactMap {
            try RemoteXPCMessageCodec.decodeFirstMessage(from: $0.payload)?
                .message
        }
        .first { $0.messageIdentifier == 1 }
    let root = try XCTUnwrap(request?.value?.dictionaryValue)
    return (
        root["routine"]?.stringValue,
        root["argv"]?.dictionaryValue ?? [:]
    )
}

/// Reassembles each file transfer's bytes keyed by transfer identifier.
private func uploadedPayloads(
    on connection: FakeConnection
) throws -> [UInt64: Data] {
    var identifiers: [UInt32: UInt64] = [:]
    var payloads: [UInt64: Data] = [:]
    for frame in try sentFrames(connection.sent.filter { $0.count >= 9 })
    where frame.type == 0x00 && frame.streamIdentifier > 3 {
        if let identifier = identifiers[frame.streamIdentifier] {
            payloads[identifier, default: Data()].append(frame.payload)
        } else {
            let open = try XCTUnwrap(
                RemoteXPCMessageCodec.decodeFirstMessage(from: frame.payload)
            ).message
            identifiers[frame.streamIdentifier] = open.messageIdentifier
            payloads[open.messageIdentifier] = Data()
        }
    }
    return payloads
}

private final class CryptexdConnectionQueue: @unchecked Sendable {
    private var pending: [FakeConnection]
    private(set) var opened: [FakeConnection] = []

    init(_ connections: [FakeConnection]) {
        pending = connections
    }

    /// Returns the connection opened at `index`, failing the test without
    /// trapping when fewer were opened.
    func connection(_ index: Int) throws -> FakeConnection {
        guard opened.indices.contains(index) else {
            XCTFail("Only \(opened.count) cryptexd connections were opened.")
            throw RorkDeviceError.transport("Missing cryptexd connection.")
        }
        return opened[index]
    }

    func open() async throws -> DeviceConnection {
        guard !pending.isEmpty else {
            throw RorkDeviceError.transport(
                "No fake cryptexd connection remains."
            )
        }
        let connection = pending.removeFirst()
        opened.append(connection)
        return connection
    }
}

private final class RecordingCryptexTicketRequester:
    CryptexTicketRequesting,
    @unchecked Sendable
{
    private let ticket: Data
    private(set) var nonce: Data?
    private(set) var identifiers: CryptexPersonalizationIdentifiers?

    init(ticket: Data) {
        self.ticket = ticket
    }

    func cryptexTicket(
        for _: CryptexDeveloperDiskImagePayload,
        identifiers: CryptexPersonalizationIdentifiers,
        nonce: Data
    ) async throws -> Data {
        self.nonce = nonce
        self.identifiers = identifiers
        return ticket
    }
}
