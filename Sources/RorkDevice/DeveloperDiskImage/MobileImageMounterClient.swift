import Foundation

/// Failure that requires reopening mobile_image_mounter before querying a nonce.
private struct PersonalizationManifestUnavailable: Error {}

/// Protocol client for iOS 17+ personalized image-mounter commands.
private struct MobileImageMounterClient {
    private static let personalizedImageType = "DeveloperDiskImage"

    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func isPersonalizedImageMounted() async throws -> Bool {
        try await send([
            "Command": "LookupImage",
            "ImageType": "Personalized",
        ])
        let response = try await receive(command: "LookupImage")

        if let isPresent = response.bool("ImagePresent") {
            return isPresent
        }
        if let signature = response["ImageSignature"] as? Data {
            return !signature.isEmpty
        }
        if let signatures = response["ImageSignature"] as? [Data] {
            return signatures.contains { !$0.isEmpty }
        }
        if let signatures = response["ImageSignature"] as? [Any] {
            return signatures.contains {
                ($0 as? Data)?.isEmpty == false
            }
        }
        throw RorkDeviceError.protocolViolation(
            "LookupImage response did not report whether a personalized image is mounted."
        )
    }

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
            additionalValues: values.filter {
                $0.key.hasPrefix("Ap,")
            }
        )
    }

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
            // This command may close the service when the device has no cached
            // manifest. The protocol requires a fresh service for QueryNonce.
            throw PersonalizationManifestUnavailable()
        }
        guard response["Error"] == nil,
            response["DetailedError"] == nil,
            let signature = response["ImageSignature"] as? Data,
            !signature.isEmpty
        else {
            throw PersonalizationManifestUnavailable()
        }
        return signature
    }

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

    func hangUp() async throws {
        try await send(["Command": "Hangup"])
    }

    private func send(_ command: [String: Any]) async throws {
        try await PropertyListMessageFramer.send(
            command,
            to: connection
        )
    }

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

/// Coordinates manifest reuse, TSS fallback, upload, and mounting.
struct PersonalizedDeveloperDiskImageMounter {
    private let openConnection: () async throws -> DeviceConnection
    private let ticketRequester: any DeveloperDiskImageTicketRequesting

    init(
        openConnection: @escaping () async throws -> DeviceConnection,
        ticketRequester: any DeveloperDiskImageTicketRequesting
    ) {
        self.openConnection = openConnection
        self.ticketRequester = ticketRequester
    }

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
        if try await client.isPersonalizedImageMounted() {
            return DeveloperDiskImageMountResult(
                status: .alreadyMounted,
                ticketSource: nil
            )
        }

        let identifiers = try await client.personalizationIdentifiers()
        let payload = try image.payload(matching: identifiers)
        let ticket: Data
        let ticketSource: DeveloperDiskImageMountResult.TicketSource

        do {
            ticket = try await client.personalizationManifest(
                for: payload.imageDigest
            )
            ticketSource = .device
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
                for: payload.identity,
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
        return DeveloperDiskImageMountResult(
            status: .mounted,
            ticketSource: ticketSource
        )
    }
}
