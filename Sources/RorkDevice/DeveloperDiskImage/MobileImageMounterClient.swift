import Foundation

/// Signals that the device has no cached manifest for the image.
///
/// This sentinel is deliberately narrower than a generic transport error.
/// Callers may request a new ticket only when the device answers this specific
/// query with an error or closes it, not when communication fails for another
/// reason.
private struct PersonalizationManifestUnavailable: Error {}

/// A disk image `CopyDevices` lists as mounted.
private struct MountedDiskImage {
    /// File the device mounted the image from, when the entry names one.
    let backingImage: String?

    /// Whether cryptexd installed the image, so only cryptexd can remove it.
    ///
    /// A Developer Disk Image that cryptexd installed is backed by
    /// `/private/var/db/com.apple.security.cryptexd/codex.system/cryptex/com.apple.MobileAsset.DDI/gdmg`,
    /// and `UnmountImage` refuses it with "Failed to unload launchd jobs"
    /// (2026-11-20, iPhone19,2, iOS 27.2.1).
    var isCryptex: Bool {
        backingImage?.hasPrefix(
            "/private/var/db/com.apple.security.cryptexd/"
        ) == true
    }
}

/// Protocol client for iOS 17+ personalized image-mounter commands.
private struct MobileImageMounterClient {
    /// Image type Apple uses for personalized developer services.
    private static let personalizedImageType = "DeveloperDiskImage"

    /// Mount point of the personalized Developer Disk Image cryptex.
    private static let personalizedMountPath = "/System/Developer"

    /// Active `com.apple.mobile.mobile_image_mounter` byte stream.
    private let connection: DeviceConnection

    /// Creates a client over one image-mounter service connection.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Reports whether a Developer Disk Image is mounted at its mount path.
    ///
    /// `LookupImage` misses an image that Xcode installed through cryptexd.
    /// On an iPhone19,2 with iOS 27.2.1 it returned no signatures while
    /// `CopyDevices` listed the cryptex-backed image at `/System/Developer`,
    /// and on an iPhone18,1 with iOS 27 `MountImage` then failed because an
    /// image was already mounted there (2026-11-20). Both queries are
    /// consulted so either kind of mount counts.
    func isDeveloperImageMounted() async throws -> Bool {
        if try await lookUpPersonalizedImages().isPresent {
            return true
        }
        return try await mountedDeveloperImage() != nil
    }

    /// Returns the disk image `CopyDevices` lists at the Developer Disk Image
    /// mount path, or `nil` when nothing is mounted there.
    func mountedDeveloperImage() async throws -> MountedDiskImage? {
        try await send(["Command": "CopyDevices"])
        let response = try await receive(command: "CopyDevices")
        guard let entries = response["EntryList"] as? [[String: Any]] else {
            throw RorkDeviceError.protocolViolation(
                "CopyDevices response did not contain EntryList."
            )
        }
        return entries.lazy
            .filter { $0["MountPath"] as? String == Self.personalizedMountPath }
            .map { MountedDiskImage(backingImage: $0["BackingImage"] as? String) }
            .first
    }

    /// Reads the hardware values needed to select a matching build identity.
    func personalizationIdentifiers() async throws
        -> PersonalizationIdentifiers
    {
        try await send([
            "Command": "QueryPersonalizationIdentifiers",
            "PersonalizedImageType": Self.personalizedImageType,
        ])
        let response = try await receive(
            command: "QueryPersonalizationIdentifiers"
        )
        guard let values = response["PersonalizationIdentifiers"]
            as? [String: Any],
            let boardID = propertyListUInt64(values["BoardId"]),
            let chipID = propertyListUInt64(values["ChipID"]),
            let securityDomain = propertyListUInt64(
                values["SecurityDomain"]
            )
        else {
            throw RorkDeviceError.protocolViolation(
                "QueryPersonalizationIdentifiers response was missing hardware identifiers."
            )
        }
        return PersonalizationIdentifiers(
            boardID: boardID,
            chipID: chipID,
            securityDomain: securityDomain,
            additionalTSSParameters: values.filter {
                $0.key.hasPrefix("Ap,")
            }
        )
    }

    /// Returns a cached personalization manifest for the image digest.
    ///
    /// The device reports a missing manifest by closing this service or by
    /// answering with an error. Other transport failures remain actionable
    /// errors.
    func personalizationManifest(for imageDigest: Data) async throws -> Data {
        try await send([
            "Command": "QueryPersonalizationManifest",
            "PersonalizedImageType": Self.personalizedImageType,
            "ImageType": Self.personalizedImageType,
            "ImageSignature": imageDigest,
        ])

        let response: [String: Any]
        do {
            response = try await PropertyListMessageFramer.receive(
                from: connection
            )
        } catch {
            guard isPeerClosedConnectionError(error) else {
                throw error
            }
            throw PersonalizationManifestUnavailable()
        }
        // iOS 27.0.1 answers a cache miss with an InternalError naming the
        // missing im4m instead of closing the service (2026-11-20, iPhone18,1).
        if response.string("Error") != nil {
            throw PersonalizationManifestUnavailable()
        }
        if let detail = response.string("DetailedError") {
            throw RorkDeviceError.lockdown(
                "QueryPersonalizationManifest failed: \(detail)"
            )
        }
        guard let signature = response["ImageSignature"] as? Data,
            !signature.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "QueryPersonalizationManifest response did not contain ImageSignature."
            )
        }
        return signature
    }

    /// Returns a fresh nonce for an Apple TSS personalization request.
    func personalizationNonce() async throws -> Data {
        try await send([
            "Command": "QueryNonce",
            "HostProcessName": "CoreDeviceService",
            "PersonalizedImageType": Self.personalizedImageType,
        ])
        let response = try await receive(command: "QueryNonce")
        guard let nonce = response["PersonalizationNonce"] as? Data,
            !nonce.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "QueryNonce response did not contain PersonalizationNonce."
            )
        }
        return nonce
    }

    /// Streams the disk image after the device accepts its size and ticket.
    ///
    /// The image stays file-backed so a multi-gigabyte DDI is never retained
    /// in memory as one `Data` value.
    func uploadImage(
        at imageURL: URL,
        ticket: Data
    ) async throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: imageURL)
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not open Developer Disk Image: \(error.localizedDescription)"
            )
        }
        defer {
            try? handle.close()
        }

        let imageSize: UInt64
        do {
            imageSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not read Developer Disk Image size: \(error.localizedDescription)"
            )
        }
        guard imageSize > 0 else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image is empty."
            )
        }

        try await send([
            "Command": "ReceiveBytes",
            "ImageSignature": ticket,
            "ImageSize": imageSize,
            "ImageType": "Personalized",
        ])
        let acknowledgement = try await receive(command: "ReceiveBytes")
        guard acknowledgement.string("Status") == "ReceiveBytesAck" else {
            throw RorkDeviceError.protocolViolation(
                "ReceiveBytes response did not acknowledge the image upload."
            )
        }

        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024),
                !chunk.isEmpty
            {
                try await connection.send(chunk)
            }
        } catch let error as RorkDeviceError {
            throw error
        } catch {
            throw RorkDeviceError.transport(
                "Developer Disk Image upload failed: \(error.localizedDescription)"
            )
        }
        let completion = try await receive(command: "image upload")
        guard completion.string("Status") == "Complete" else {
            throw RorkDeviceError.protocolViolation(
                "Developer Disk Image upload did not complete."
            )
        }
    }

    /// Mounts an uploaded image with its ticket and validated trust cache.
    func mount(ticket: Data, trustCache: Data) async throws {
        try await send([
            "Command": "MountImage",
            "ImageSignature": ticket,
            "ImageType": "Personalized",
            "ImageTrustCache": trustCache,
        ])
        let response = try await receive(command: "MountImage")
        guard response.string("Status") == "Complete" else {
            throw RorkDeviceError.protocolViolation(
                "MountImage response did not report completion."
            )
        }
    }

    /// Unmounts the personalized Developer Disk Image cryptex, if one is mounted.
    ///
    /// The device surfaces its own error when nothing is mounted at the path, so
    /// callers that only want a best-effort teardown should check
    /// `isDeveloperImageMounted()` first.
    func unmount() async throws {
        try await send([
            "Command": "UnmountImage",
            "MountPath": Self.personalizedMountPath,
        ])
        let response = try await receive(command: "UnmountImage")
        guard response.string("Status") == "Complete" else {
            throw RorkDeviceError.protocolViolation(
                "UnmountImage response did not report completion."
            )
        }
    }

    /// Returns the signatures of the personalized images the device reports
    /// mounted, or an empty array when none are mounted.
    func mountedImageSignatures() async throws -> [Data] {
        try await lookUpPersonalizedImages().signatures
    }

    /// Parsed `LookupImage` result for the personalized image type.
    private struct PersonalizedImageLookup {
        /// Whether the device reports a personalized image mounted.
        let isPresent: Bool

        /// Signatures the device reports for mounted personalized images.
        let signatures: [Data]
    }

    /// Runs one `LookupImage` query and decodes the shared response shape.
    ///
    /// The device has conveyed mount state through `ImagePresent` and through
    /// `ImageSignature` across iOS versions, so both readers share this decode
    /// to stay aligned when the response shape changes.
    private func lookUpPersonalizedImages() async throws
        -> PersonalizedImageLookup
    {
        try await send([
            "Command": "LookupImage",
            "ImageType": "Personalized",
        ])
        let response = try await receive(command: "LookupImage")
        let signatures = Self.imageSignatures(in: response)
        if let isPresent = response.bool("ImagePresent") {
            return PersonalizedImageLookup(
                isPresent: isPresent,
                signatures: signatures
            )
        }
        guard response["ImageSignature"] != nil else {
            throw RorkDeviceError.protocolViolation(
                "LookupImage response did not report whether a personalized image is mounted."
            )
        }
        return PersonalizedImageLookup(
            isPresent: !signatures.isEmpty,
            signatures: signatures
        )
    }

    /// Extracts every non-empty image signature from a `LookupImage` response.
    ///
    /// The mounter has returned the signature as a lone value or an array across
    /// iOS versions, so each shape is normalized to a list.
    private static func imageSignatures(
        in response: [String: Any]
    ) -> [Data] {
        if let signature = response["ImageSignature"] as? Data {
            return signature.isEmpty ? [] : [signature]
        }
        if let signatures = response["ImageSignature"] as? [Data] {
            return signatures.filter { !$0.isEmpty }
        }
        if let signatures = response["ImageSignature"] as? [Any] {
            return signatures
                .compactMap { $0 as? Data }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// Ends the image-mounter session after a successful mount.
    func hangUp() async throws {
        try await send(["Command": "Hangup"])
    }

    /// Sends one framed image-mounter command.
    private func send(_ command: [String: Any]) async throws {
        try await PropertyListMessageFramer.send(
            command,
            to: connection
        )
    }

    /// Receives one response and preserves Apple error details in the failure.
    private func receive(command: String) async throws -> [String: Any] {
        let response = try await PropertyListMessageFramer.receive(
            from: connection
        )
        if let error = response.string("Error") {
            let detail = response.string("DetailedError")
                ?? response.string("ErrorDescription")
            let suffix = detail.map { ": \($0)" } ?? ""
            throw RorkDeviceError.lockdown(
                "\(command) failed: \(error)\(suffix)"
            )
        }
        if let detail = response.string("DetailedError") {
            throw RorkDeviceError.lockdown(
                "\(command) failed: \(detail)"
            )
        }
        return response
    }
}

/// Returns whether the peer ended a NIO byte stream before sending a response.
private func isPeerClosedConnectionError(_ error: Error) -> Bool {
    guard case RorkDeviceError.connectionClosed = error else {
        return false
    }
    return true
}

/// Coordinates manifest reuse, TSS fallback, upload, and mounting.
struct PersonalizedDeveloperDiskImageMounter {
    /// Opens a fresh image-mounter service after a manifest cache miss.
    private let openConnection: () async throws -> DeviceConnection

    /// Requests an Apple ticket when the device has no reusable manifest.
    private let ticketRequester: any DeveloperDiskImageTicketRequesting

    /// Installs the image's Cryptex1 identity, used when the manifest lists
    /// no personalized identity for the device.
    private let mountCryptex:
        ((PersonalizedDeveloperDiskImage) async throws
            -> DeveloperDiskImageMountResult)?

    /// Creates a mounter with replaceable connection and ticket boundaries.
    init(
        openConnection: @escaping () async throws -> DeviceConnection,
        ticketRequester: any DeveloperDiskImageTicketRequesting,
        mountCryptex: (
            (PersonalizedDeveloperDiskImage) async throws
                -> DeveloperDiskImageMountResult
        )? = nil
    ) {
        self.openConnection = openConnection
        self.ticketRequester = ticketRequester
        self.mountCryptex = mountCryptex
    }

    /// Reuses a cached ticket when possible, otherwise requests one from TSS.
    ///
    /// A manifest cache miss closes the initial service, so the nonce and
    /// upload sequence must continue on a freshly opened connection. A device
    /// the manifest lists no personalized identity for gets the Cryptex1
    /// identity instead, when the manifest has one.
    func mount(
        _ image: PersonalizedDeveloperDiskImage,
        ecid: UInt64
    ) async throws -> DeveloperDiskImageMountResult {
        let initialConnection = try await openConnection()
        var connection: DeviceConnection? = initialConnection
        defer {
            connection?.close()
        }

        var client = MobileImageMounterClient(
            connection: initialConnection
        )
        if try await client.isDeveloperImageMounted() {
            return .alreadyMounted
        }

        let identifiers = try await client.personalizationIdentifiers()
        if !image.hasPersonalizedIdentity(matching: identifiers),
            image.hasCryptexIdentity,
            let mountCryptex
        {
            connection?.close()
            connection = nil
            return try await mountCryptex(image)
        }
        let payload = try image.payload(matching: identifiers)
        let ticket: Data
        let ticketSource: DeveloperDiskImageMountResult.TicketSource

        do {
            ticket = try await client.personalizationManifest(
                for: payload.imageDigest
            )
            ticketSource = .deviceManifest
        } catch is PersonalizationManifestUnavailable {
            connection?.close()
            connection = nil

            let replacementConnection = try await openConnection()
            connection = replacementConnection
            client = MobileImageMounterClient(
                connection: replacementConnection
            )
            let nonce = try await client.personalizationNonce()
            ticket = try await ticketRequester.ticket(
                for: payload.buildIdentity,
                identifiers: identifiers,
                nonce: nonce,
                ecid: ecid
            )
            ticketSource = .appleTSS
        }

        try await client.uploadImage(
            at: payload.imageURL,
            ticket: ticket
        )
        let trustCache: Data
        do {
            trustCache = try Data(
                contentsOf: payload.trustCacheURL,
                options: .mappedIfSafe
            )
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not read Developer Disk Image trust cache: \(error.localizedDescription)"
            )
        }
        try await client.mount(
            ticket: ticket,
            trustCache: trustCache
        )
        try await client.hangUp()
        return .mounted(ticketSource: ticketSource)
    }
}

/// Unmounts the personalized Developer Disk Image, through cryptexd when
/// cryptexd installed it.
struct PersonalizedDeveloperDiskImageUnmounter {
    /// Opens a fresh image-mounter service connection.
    private let openConnection: () async throws -> DeviceConnection

    /// Uninstalls the Developer Disk Image cryptex and reports whether
    /// cryptexd had one installed.
    private let uninstallCryptex: (() async throws -> Bool)?

    /// Creates an unmounter with replaceable connection and cryptexd
    /// boundaries.
    init(
        openConnection: @escaping () async throws -> DeviceConnection,
        uninstallCryptex: (() async throws -> Bool)? = nil
    ) {
        self.openConnection = openConnection
        self.uninstallCryptex = uninstallCryptex
    }

    /// Removes the image at the Developer Disk Image mount path.
    ///
    /// cryptexd is asked when the mounted image is its cryptex and when
    /// nothing is mounted, since a cryptex it still lists would block the
    /// next install. Any other image, or no cryptex at all, goes through
    /// `UnmountImage`, which reports the device's own error when nothing is
    /// mounted.
    func unmount() async throws {
        let mounted = try await withClient {
            try await $0.mountedDeveloperImage()
        }
        if mounted?.isCryptex ?? true,
            let uninstallCryptex,
            try await uninstallCryptex()
        {
            return
        }
        try await withClient { try await $0.unmount() }
    }

    /// Runs one exchange on its own image-mounter connection, so none stays
    /// open while cryptexd works.
    private func withClient<Result>(
        _ body: (MobileImageMounterClient) async throws -> Result
    ) async throws -> Result {
        let connection = try await openConnection()
        defer {
            connection.close()
        }
        return try await body(MobileImageMounterClient(connection: connection))
    }
}

/// Reports the personalized Developer Disk Images the device has mounted.
struct PersonalizedDeveloperDiskImageLister {
    /// Opens a fresh image-mounter service connection.
    private let openConnection: () async throws -> DeviceConnection

    /// Creates a lister with a replaceable connection boundary.
    init(openConnection: @escaping () async throws -> DeviceConnection) {
        self.openConnection = openConnection
    }

    /// Opens the image-mounter service and returns mounted image signatures.
    func mountedImageSignatures() async throws -> [Data] {
        let connection = try await openConnection()
        defer {
            connection.close()
        }
        return try await MobileImageMounterClient(
            connection: connection
        ).mountedImageSignatures()
    }
}
