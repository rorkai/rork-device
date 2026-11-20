import Foundation

/// One cryptex that cryptexd reports as installed through its remote service.
struct InstalledCryptex: Equatable, Sendable {
    /// `CFBundleIdentifier` of the cryptex's `cryptex_info`.
    let identifier: String

    /// `CFBundleVersion` of the cryptex's `cryptex_info`.
    let version: String
}

/// RemoteXPC client for `com.apple.security.cryptexd.remote`.
///
/// Requests name a `routine` and its `argv` and are answered on the reply
/// stream. The routine names, arguments, and reply keys follow go-ios's
/// `ios/imagemounter/cryptex.go`, which captured them from CoreDevice
/// installing Xcode's Developer Disk Image (2026-11-20).
///
/// Every routine runs on a connection of its own, because cryptexd closed
/// the connection after answering one routine on an iPhone19,2 with iOS
/// 27.2.1 (2026-11-20).
private struct CryptexServiceClient {
    /// RemoteXPC flag marking requests that expect a reply.
    private static let requestFlag: UInt32 = 0x00010000

    /// Client version CoreDevice sends to cryptexd.
    private static let clientVersion = RemoteXPCValue.uint64(3)

    /// Opens a fresh raw cryptexd service connection.
    private let openConnection: () async throws -> DeviceConnection

    /// Creates a client that opens one connection per routine.
    init(openConnection: @escaping () async throws -> DeviceConnection) {
        self.openConnection = openConnection
    }

    /// Lists the cryptexes installed through the remote service.
    func installedCryptexes() async throws -> [InstalledCryptex] {
        let argv = try await call(
            "copy-installed",
            argv: [:]
        )
        guard case let .array(entries)? = argv["remote-cryptex-array"] else {
            return []
        }
        return entries.compactMap { entry in
            entry.dictionaryValue.flatMap(Self.installedCryptex)
        }
    }

    /// Reads the Image4 chip properties that select a Cryptex1 identity.
    func personalizationIdentifiers() async throws
        -> CryptexPersonalizationIdentifiers
    {
        let argv = try await call(
            "read-personalization-id",
            argv: ["client-version": Self.clientVersion]
        )
        func property(_ name: String) throws -> UInt64 {
            guard let value = argv["img4_chip_\(name)"]?.unsignedIntegerValue
            else {
                throw RorkDeviceError.protocolViolation(
                    "cryptexd read-personalization-id response is missing img4_chip_\(name)."
                )
            }
            return value
        }
        return CryptexPersonalizationIdentifiers(
            chipID: try property("chip"),
            ecid: try property("ecid"),
            cryptexChipID: try property("fchp"),
            cryptexType: try property("type"),
            productClass: try property("clas"),
            isProductionMode: try property("cpro") != 0,
            isSecureMode: try property("csec") != 0
        )
    }

    /// Returns the device nonce Apple TSS must sign for a nonce domain.
    func nonce(domain: UInt64) async throws -> Data {
        let argv = try await call(
            "get-nonce",
            argv: ["nonce-domain-handle": .uint64(domain)]
        )
        guard let nonce = argv["nonce"]?.dataValue else {
            throw RorkDeviceError.protocolViolation(
                "cryptexd get-nonce response does not contain a nonce."
            )
        }
        return try img4Nonce(from: nonce)
    }

    /// Installs a personalized cryptex and returns what cryptexd installed.
    ///
    /// The arguments match what CoreDevice sends for the Developer Disk
    /// Image, and each file travels as a RemoteXPC file transfer.
    func install(
        _ payload: CryptexDeveloperDiskImagePayload,
        ticket: Data
    ) async throws -> InstalledCryptex? {
        let uploads: [(argument: String, payload: RemoteXPCUploadPayload)] = [
            ("image", .file(payload.imageURL)),
            ("volumehash", .file(payload.volumeHashURL)),
            ("info", .file(payload.infoURL)),
            ("trustcache", .file(payload.trustCacheURL)),
            ("im4m", .data(ticket)),
        ]
        let connection = try await RemoteXPCConnection.open(
            over: openConnection()
        )
        defer {
            connection.close()
        }
        try await connection.send(
            uploading: uploads.map(\.payload),
            additionalFlags: Self.requestFlag
        ) { transfers in
            var argv: [String: RemoteXPCValue] = [
                "auth": .uint64(0),
                "client-version": Self.clientVersion,
                "cryptex1-properties": .dictionary([
                    "Cryptex1,NonceDomain": .uint64(payload.nonceDomain),
                    "Cryptex1,PreauthVersion": .string(
                        payload.preauthorizationVersion
                    ),
                    "Cryptex1,SubType": .uint64(payload.subType),
                    "Cryptex1,UseProductClass": .bool(
                        payload.usesProductClass
                    ),
                    "Cryptex1,Version": .string(payload.version),
                    "MountedCryptex": .bool(false),
                ]),
                "image-type-index": .int64(10),
                "nonce-persistence": .uint64(1),
                "persistence": .uint64(2),
            ]
            for (upload, transfer) in zip(uploads, transfers) {
                argv[upload.argument] = transfer
            }
            return Self.request("install", argv: argv)
        }
        let argv = try await reply(to: "install", on: connection)
        return argv["remote-cryptex"]?.dictionaryValue.flatMap(
            Self.installedCryptex
        )
    }

    /// Uninstalls an installed cryptex, which also unmounts its image.
    ///
    /// The argument follows pymobiledevice3's `services/cryptexd.py`, which
    /// also records errno 2 for a cryptex that is not installed. Uninstalling
    /// the Developer Disk Image on an iPhone19,2 with iOS 27.2.1 emptied both
    /// copy-installed and `CopyDevices` without a reboot (2026-11-20).
    func uninstall(identifier: String) async throws {
        _ = try await call(
            "uninstall",
            argv: ["remote-cryptex-identifier": .string(identifier)]
        )
    }

    /// Sends one routine on a fresh connection and returns its reply `argv`.
    private func call(
        _ routine: String,
        argv: [String: RemoteXPCValue]
    ) async throws -> [String: RemoteXPCValue] {
        let connection = try await RemoteXPCConnection.open(
            over: openConnection()
        )
        defer {
            connection.close()
        }
        try await connection.send(
            Self.request(routine, argv: argv),
            additionalFlags: Self.requestFlag
        )
        return try await reply(to: routine, on: connection)
    }

    /// Reads one reply and surfaces cryptexd's `cferr` or `error` refusals.
    private func reply(
        to routine: String,
        on connection: RemoteXPCConnection
    ) async throws -> [String: RemoteXPCValue] {
        let message = try await connection.receive(on: .reply)
        guard let root = message.value?.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "cryptexd answered \(routine) without a dictionary."
            )
        }
        if let error = root["cferr"] {
            throw RorkDeviceError.cryptexd(
                "\(routine) failed: \(String(describing: error))"
            )
        }
        if let code = root["error"]?.unsignedIntegerValue, code != 0 {
            throw RorkDeviceError.cryptexd(
                "\(routine) failed with errno \(code)."
            )
        }
        return root["argv"]?.dictionaryValue ?? [:]
    }

    /// Builds the routine envelope cryptexd expects.
    private static func request(
        _ routine: String,
        argv: [String: RemoteXPCValue]
    ) -> RemoteXPCValue {
        .dictionary([
            "argv": .dictionary(argv),
            "routine": .string(routine),
        ])
    }

    /// Decodes one installed-cryptex dictionary.
    private static func installedCryptex(
        _ values: [String: RemoteXPCValue]
    ) -> InstalledCryptex? {
        guard let identifier = values["remote-cryptex-identifier"]?
            .stringValue
        else {
            return nil
        }
        return InstalledCryptex(
            identifier: identifier,
            version: values["remote-cryptex-version"]?.stringValue ?? ""
        )
    }
}

/// Extracts the nonce from a serialized `img4_nonce_t`.
///
/// The structure holds a 16-bit version, 48 nonce bytes, padding, and the
/// nonce length as a little-endian 32-bit value at offset 52.
func img4Nonce(from serialized: Data) throws -> Data {
    let maximumLength = 48
    guard serialized.count == 56 else {
        throw RorkDeviceError.protocolViolation(
            "cryptexd returned a \(serialized.count)-byte nonce instead of a 56-byte img4_nonce_t."
        )
    }
    let length: UInt32 = try serialized.littleEndianInteger(at: 52)
    guard length > 0, length <= maximumLength else {
        throw RorkDeviceError.protocolViolation(
            "cryptexd returned an img4_nonce_t with invalid length \(length)."
        )
    }
    let start = serialized.startIndex + 2
    return Data(serialized[start..<(start + Int(length))])
}

/// Installs the Cryptex1 Developer Disk Image through cryptexd.
///
/// Devices newer than an image's board list cannot mount it through
/// `mobile_image_mounter`, but iOS accepts its Cryptex1 identity, which Apple
/// TSS personalizes for any device it supports. cryptexd is reachable only
/// through Remote Service Discovery.
struct CryptexDeveloperDiskImageMounter {
    /// Exact service name advertised by Remote Service Discovery.
    static let serviceName = "com.apple.security.cryptexd.remote"

    /// `CFBundleIdentifier` of the Developer Disk Image's `cryptex_info`.
    static let developerDiskImageIdentifier = "com.apple.MobileAsset.DDI"

    /// cryptexd routines, each on its own connection.
    private let client: CryptexServiceClient

    /// Requests the Cryptex1 ticket from Apple.
    private let ticketRequester: any CryptexTicketRequesting

    /// Creates a mounter with replaceable connection and ticket boundaries.
    init(
        openConnection: @escaping () async throws -> DeviceConnection,
        ticketRequester: any CryptexTicketRequesting
    ) {
        client = CryptexServiceClient(openConnection: openConnection)
        self.ticketRequester = ticketRequester
    }

    /// Installs the image's Cryptex1 identity.
    ///
    /// Callers reach this only after the image mounter reported nothing
    /// mounted at `/System/Developer`. A Developer Disk Image cryptex that is
    /// still installed then has no mounted image, and installing over it
    /// fails with EEXIST, as pymobiledevice3 observed on an iPhone19,4 with
    /// iOS 27.2.1 (2026-11-20, services/cryptexd.py). It is uninstalled
    /// first.
    func mount(
        _ image: PersonalizedDeveloperDiskImage
    ) async throws -> DeveloperDiskImageMountResult {
        _ = try await uninstallDeveloperDiskImage()
        let identifiers = try await client.personalizationIdentifiers()
        let payload = try image.cryptexPayload(matching: identifiers)
        let nonce = try await client.nonce(domain: payload.nonceDomain)
        let ticket = try await ticketRequester.cryptexTicket(
            for: payload,
            identifiers: identifiers,
            nonce: nonce
        )
        _ = try await client.install(payload, ticket: ticket)
        return .mounted(ticketSource: .appleTSS)
    }

    /// Uninstalls the Developer Disk Image cryptex and reports whether one
    /// was installed.
    func uninstallDeveloperDiskImage() async throws -> Bool {
        guard try await client.installedCryptexes().contains(where: {
            $0.identifier == Self.developerDiskImageIdentifier
        }) else {
            return false
        }
        try await client.uninstall(
            identifier: Self.developerDiskImageIdentifier
        )
        return true
    }
}
