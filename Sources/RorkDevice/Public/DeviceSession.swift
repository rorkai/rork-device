import Foundation

/// Connected device service environment for installation and diagnostics.
///
/// A session hides how service endpoints are discovered. Lockdown-backed
/// sessions start services through an authenticated Lockdown connection, while
/// remote sessions connect to ports advertised by Remote Service Discovery and
/// complete the required RSD check-in. The higher-level AFC, MISAgent,
/// heartbeat, HouseArrest, InstallationProxy, and companion proxy workflows
/// are identical for both routes.
///
/// Each operation opens the service connection it needs. Callers may therefore
/// retain a session for a complete install workflow without managing individual
/// service ports or protocol handshakes.
///
/// The unchecked conformance is safe at the memory level because the session
/// and its backends store only immutable references. Remote Service Discovery
/// sessions additionally support concurrent operations, since every operation
/// opens its own service connection through the shared directory. Lockdown
/// sessions serialize a request/response protocol over one control connection,
/// so their operations must not overlap in time.
///
/// Every throwing operation exposes only `RorkDeviceError`. Service clients and
/// backend implementations may use broader errors internally, which the
/// session normalizes before returning to its caller.
///
/// Methods that return `DeviceConnection`, `AFCClient`, `DeviceHeartbeat`, or
/// `CoreDeviceTunnel` transfer ownership of that live service to the caller.
/// Close or stop the returned value when it is no longer needed. Operations
/// that return ordinary values use short-lived services and close those
/// connections before returning or throwing.
public final class DeviceSession: @unchecked Sendable {
    /// Kept outside `LockdownServiceName` because new public enum cases break
    /// exhaustive switches in existing clients.
    private static let personalizedDeveloperDiskImageServiceName =
        "com.apple.mobile.mobile_image_mounter"

    /// Backend that resolves and opens services for this session's transport.
    private let backend: DeviceSessionBackend

    /// Creates a Lockdown-backed session from an authenticated connection.
    init(
        transport: DeviceTransport,
        lockdown: LockdownClient,
        pairingRecord: PairingRecord,
        label: String,
        secureSessionUpgrader: SecureSessionUpgrader
    ) {
        backend = LockdownDeviceSessionBackend(
            transport: transport,
            lockdown: lockdown,
            pairingRecord: pairingRecord,
            secureSessionUpgrader: secureSessionUpgrader
        )
    }

    /// Creates a session around a transport-independent service backend.
    init(backend: DeviceSessionBackend) {
        self.backend = backend
    }

    /// Releases the session's persistent control connections.
    ///
    /// Service connections returned by the session are owned by their callers
    /// and stay open. Short-lived processes can rely on process exit instead;
    /// long-lived hosts such as the tunnel reconnect loop must close each
    /// session they abandon so control connections do not accumulate. The
    /// session must not be used after closing.
    public func close() {
        backend.close()
    }

    /// Returns the identity information available for the connected device.
    ///
    /// Lockdown sessions return common values from the device's default value
    /// domain. Remote Service Discovery sessions return the device identifier
    /// recorded in their service manifest. This makes the method suitable for
    /// validating that a session targets the expected physical device without
    /// requiring callers to know which transport created it.
    ///
    /// - Returns: Device identity and OS fields available from the active
    ///   session backend.
    /// - Throws: `RorkDeviceError.transport` or
    ///   `RorkDeviceError.protocolViolation` when the backend cannot obtain
    ///   valid device information.
    public func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        try await withRorkDeviceError {
            try await backend.fetchDeviceInfo()
        }
    }

    /// Reads one typed registry value from a paired companion device.
    ///
    /// Each call opens a fresh companion proxy service because some iOS
    /// versions close the service after one response.
    ///
    /// - Parameters:
    ///   - key: Open registry key carrying the expected response type.
    ///   - deviceIdentifier: Identifier returned by
    ///     `pairedCompanionDevices()` or
    ///     `CompanionProxyClient.pairedDeviceIdentifiers()`.
    /// - Returns: The typed value, or `nil` when the key is absent.
    /// - Throws: `RorkDeviceError.invalidInput` for an empty key or identifier,
    ///   or another `RorkDeviceError` for transport or protocol failure.
    public func companionValue<Value>(
        for key: CompanionRegistryKey<Value>,
        on deviceIdentifier: String
    ) async throws(RorkDeviceError) -> Value? {
        try await withRorkDeviceError {
            try validateCompanionRegistryLookup(
                key: key,
                deviceIdentifier: deviceIdentifier
            )
            return try await withCompanionProxyClient {
                try await $0.value(
                    for: key,
                    on: deviceIdentifier
                )
            }
        }
    }

    /// Reads one custom registry value using an explicit response type.
    ///
    /// Use the typed-key overload for known or reusable keys. This overload is
    /// the concise escape hatch for runtime key names.
    ///
    /// - Parameters:
    ///   - type: Expected property-list value type.
    ///   - key: Raw registry key name.
    ///   - deviceIdentifier: Identifier returned by
    ///     `pairedCompanionDevices()` or
    ///     `CompanionProxyClient.pairedDeviceIdentifiers()`.
    /// - Returns: The typed value, or `nil` when the key is absent.
    /// - Throws: `RorkDeviceError.invalidInput` for an empty key or identifier,
    ///   or another `RorkDeviceError` for transport or protocol failure.
    public func companionValue<Value>(
        _ type: Value.Type,
        forKey key: String,
        on deviceIdentifier: String
    ) async throws(RorkDeviceError) -> Value? {
        try await companionValue(
            for: CompanionRegistryKey<Value>(key),
            on: deviceIdentifier
        )
    }

    /// Returns devices paired through the connected iPhone.
    ///
    /// The session opens Apple's companion proxy through either Lockdown or its
    /// Remote Service Discovery shim. Device name and model fields are optional
    /// because the registry may omit either value.
    ///
    /// - Returns: Paired companion-device identity information.
    /// - Throws: `RorkDeviceError.transport` or
    ///   `RorkDeviceError.protocolViolation` when the service cannot return a
    ///   valid registry.
    public func pairedCompanionDevices() async throws(RorkDeviceError)
        -> [PairedCompanionDevice]
    {
        try await withRorkDeviceError {
            let identifiers = try await withCompanionProxyClient {
                try await $0.pairedDeviceIdentifiers()
            }

            var devices: [PairedCompanionDevice] = []
            devices.reserveCapacity(identifiers.count)

            for identifier in identifiers {
                let name: String? = try await companionValue(
                    for: .deviceName,
                    on: identifier
                )
                let modelNumber: String? = try await companionValue(
                    for: .modelNumber,
                    on: identifier
                )
                devices.append(
                    PairedCompanionDevice(
                        udid: identifier,
                        name: name,
                        modelNumber: modelNumber
                    )
                )
            }
            return devices
        }
    }

    /// Runs one companion proxy request on a fresh service connection.
    ///
    /// Some iOS versions close this service after one response, so reusing a
    /// stream can lose later metadata even after registry discovery succeeds.
    ///
    /// - Parameter operation: This request runs before the service is closed.
    /// - Returns: The request produces this value.
    /// - Throws: The method propagates the service or protocol failure.
    private func withCompanionProxyClient<Result>(
        _ operation: (CompanionProxyClient) async throws -> Result
    ) async throws -> Result {
        let connection = try await startService(
            named: CompanionProxyClient.serviceName
        )
        defer {
            connection.close()
        }
        return try await operation(
            CompanionProxyClient(connection: connection)
        )
    }

    /// Returns whether Developer Mode is enabled on the connected device.
    ///
    /// The query reads the AMFI Lockdown value used by iOS itself. It is
    /// passive and does not reveal or change the setting.
    ///
    /// - Returns: `true` when the device reports Developer Mode as enabled.
    /// - Throws: `RorkDeviceError.lockdown` or `RorkDeviceError.transport`, or
    ///   `RorkDeviceError.protocolViolation` when this session route cannot
    ///   access Lockdown value domains.
    public func isDeveloperModeEnabled() async throws(RorkDeviceError) -> Bool {
        try await withRorkDeviceError {
            try await backend.isDeveloperModeEnabled()
        }
    }

    /// Enables host connections through the device's wireless Lockdown route.
    ///
    /// This is the programmatic equivalent of enabling "Show this iPhone when
    /// on Wi-Fi" in Finder. It is required by local VPN-based workflows that
    /// expose the device's Lockdown endpoint back to an app on the same iPhone.
    ///
    /// The session must use an authenticated Lockdown connection, normally over
    /// USB. Remote Service Discovery sessions cannot change this device setting.
    ///
    /// - Throws: `RorkDeviceError.lockdown` when iOS rejects the setting, or
    ///   `RorkDeviceError.protocolViolation` when the session is not backed by
    ///   Lockdown.
    public func enableWirelessConnections() async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            try await backend.enableWirelessConnections()
        }
    }

    /// Makes the Developer Mode setting visible in the device's Settings app.
    ///
    /// This operation does not enable Developer Mode or restart the device. It
    /// asks the AMFI Lockdown service to reveal the user-controlled setting so
    /// the user can finish the process in Settings > Privacy & Security.
    ///
    /// The device must already trust the host because the AMFI service is
    /// opened through the authenticated Lockdown session.
    ///
    /// - Throws: `RorkDeviceError.lockdown` when iOS rejects the request,
    ///   `RorkDeviceError.protocolViolation` when the service returns an
    ///   incomplete response, or `RorkDeviceError.transport` when the service
    ///   connection fails.
    public func revealDeveloperMode() async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            let connection = try await startService(.developerMode)
            defer {
                connection.close()
            }
            try await DeveloperModeClient(
                connection: connection
            ).reveal()
        }
    }

    /// Mounts an iOS 17+ personalized Developer Disk Image.
    ///
    /// `restoreDirectory` must contain `BuildManifest.plist` and the files it
    /// references. The session queries the connected device for its hardware
    /// identity, reuses a device-side personalization manifest when possible,
    /// and otherwise requests a fresh ticket from Apple TSS.
    ///
    /// Call this through a Lockdown-backed session before opening a CoreDevice
    /// tunnel. If `requiresTunnelRestart` is `true`, any existing tunnel must
    /// be recreated so Remote Service Discovery advertises the mounted image's
    /// developer services.
    ///
    /// - Parameter restoreDirectory: Extracted personalized DDI `Restore`
    ///   directory.
    /// - Returns: Mount status and personalization-ticket origin.
    /// - Throws: `RorkDeviceError.invalidInput` for an unsupported device,
    ///   disabled Developer Mode, or invalid image,
    ///   `RorkDeviceError.fileSystem` when local image files cannot be read, or
    ///   another `RorkDeviceError` when the operation cannot complete.
    public func mountPersonalizedDeveloperDiskImage(
        from restoreDirectory: URL
    ) async throws(RorkDeviceError) -> DeveloperDiskImageMountResult {
        try await withRorkDeviceError {
            let image = try PersonalizedDeveloperDiskImage(
                contentsOf: restoreDirectory
            )
            let ecid = try await developerDiskImageECID()
            return try await mountPersonalizedDeveloperDiskImage(
                image,
                ecid: ecid
            )
        }
    }

    /// Downloads and mounts a personalized Developer Disk Image archive.
    ///
    /// The archive is authenticated with the source's pinned SHA-256 before
    /// extraction. Applications remain responsible for selecting a lawful,
    /// trustworthy archive provider.
    ///
    /// - Parameters:
    ///   - source: HTTPS archive and expected digest.
    ///   - store: Download and extraction cache.
    /// - Returns: Mount status and personalization-ticket origin.
    /// - Throws: `RorkDeviceError.invalidInput` for an unsupported device,
    ///   disabled Developer Mode, invalid archive, or incompatible image,
    ///   `RorkDeviceError.fileSystem` when local image files cannot be read, or
    ///   another `RorkDeviceError` when the operation cannot complete.
    public func mountPersonalizedDeveloperDiskImage(
        from source: DeveloperDiskImageSource,
        using store: DeveloperDiskImageStore = DeveloperDiskImageStore()
    ) async throws(RorkDeviceError) -> DeveloperDiskImageMountResult {
        try await withRorkDeviceError {
            let ecid = try await developerDiskImageECID()
            let restoreDirectory = try await store.prepareRestoreDirectory(
                from: source
            )
            let image = try PersonalizedDeveloperDiskImage(
                contentsOf: restoreDirectory
            )
            return try await mountPersonalizedDeveloperDiskImage(
                image,
                ecid: ecid
            )
        }
    }

    /// Unmounts the personalized Developer Disk Image, if one is mounted.
    ///
    /// Developer services remain available only while an image is mounted, so
    /// this is mainly for forcing a clean re-mount; the device also clears a
    /// mounted image on reboot. The device reports its own error when nothing is
    /// mounted, so call `mountedPersonalizedDeveloperDiskImages()` first for a
    /// best-effort teardown.
    ///
    /// - Throws: `RorkDeviceError.protocolViolation` or
    ///   `RorkDeviceError.transport` when the image mounter cannot complete the
    ///   request.
    public func unmountPersonalizedDeveloperDiskImage() async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            try await PersonalizedDeveloperDiskImageUnmounter(
                openConnection: {
                    try await self.startService(
                        named: Self.personalizedDeveloperDiskImageServiceName
                    )
                }
            ).unmount()
        }
    }

    /// Returns the signatures of the personalized Developer Disk Images the
    /// device reports mounted.
    ///
    /// The result is empty when no personalized image is mounted, which is the
    /// expected state after a reboot.
    ///
    /// - Returns: One signature per mounted personalized image.
    /// - Throws: `RorkDeviceError.protocolViolation` or
    ///   `RorkDeviceError.transport` when the image mounter cannot complete the
    ///   request.
    public func mountedPersonalizedDeveloperDiskImages() async throws(RorkDeviceError) -> [Data] {
        try await withRorkDeviceError {
            try await PersonalizedDeveloperDiskImageLister(
                openConnection: {
                    try await self.startService(
                        named: Self.personalizedDeveloperDiskImageServiceName
                    )
                }
            ).mountedImageSignatures()
        }
    }

    /// Validates device state before network or image-mounter work begins.
    ///
    /// - Returns: The hardware identifier is used for image personalization.
    /// - Throws: The method throws `RorkDeviceError` when device state is
    ///   incomplete, incompatible, or not enabled for developer services.
    private func developerDiskImageECID() async throws -> UInt64 {
        let deviceInfo = try await fetchDeviceInfo()
        guard let productVersion = deviceInfo.productVersion,
            let majorVersion = productVersion.split(separator: ".").first
                .flatMap({ Int($0) })
        else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown did not report a valid ProductVersion for Developer Disk Image mounting."
            )
        }
        guard majorVersion >= 17 else {
            throw RorkDeviceError.invalidInput(
                "Personalized Developer Disk Images require iOS 17 or newer."
            )
        }
        guard try await isDeveloperModeEnabled() else {
            throw RorkDeviceError.invalidInput(
                "Developer Mode must be enabled before mounting a personalized Developer Disk Image."
            )
        }
        guard let ecid = propertyListUInt64(
            deviceInfo.rawValues["UniqueChipID"]
        ) else {
            throw RorkDeviceError.protocolViolation(
                "Lockdown did not report a valid UniqueChipID for Developer Disk Image personalization."
            )
        }
        return ecid
    }

    /// Mounts a parsed image after device compatibility has been established.
    ///
    /// - Parameters:
    ///   - image: This value contains validated files and build identities.
    ///   - ecid: This hardware identifier is used for personalization.
    /// - Returns: The result reports whether the tunnel must restart.
    /// - Throws: The method propagates image, ticket, filesystem, or transport
    ///   failure.
    private func mountPersonalizedDeveloperDiskImage(
        _ image: PersonalizedDeveloperDiskImage,
        ecid: UInt64
    ) async throws -> DeveloperDiskImageMountResult {
        return try await PersonalizedDeveloperDiskImageMounter(
            openConnection: {
                try await self.startService(
                    named: Self.personalizedDeveloperDiskImageServiceName
                )
            },
            ticketRequester: AppleTSSClient()
        ).mount(image, ecid: ecid)
    }

    /// Opens a modeled device service on the active session route.
    ///
    /// This overload covers services modeled by rork-device. Use
    /// `startService(named:escrowBag:)` for lower-level workflows that need a
    /// service identifier not yet represented by `LockdownServiceName`.
    /// Lockdown sessions request the service from lockdownd; RSD sessions resolve
    /// and connect to the corresponding `.shim.remote` endpoint.
    ///
    /// - Parameters:
    ///   - serviceName: Modeled device service identifier.
    ///   - escrowBag: Optional escrow material from a pairing record. Leave
    ///     this as `nil` unless the specific service flow requires escrow.
    /// - Returns: A connected byte stream ready for the service-specific
    ///   protocol client.
    /// - Throws: The method throws `RorkDeviceError.lockdown` when Lockdown
    ///   rejects startup, `RorkDeviceError.secureSession` or
    ///   `RorkDeviceError.secureSessionUnsupported` when a required upgrade
    ///   fails, `RorkDeviceError.protocolViolation` for a malformed Lockdown or
    ///   RSD response, `RorkDeviceError.transport` when the connection fails, or
    ///   `RorkDeviceError.cancelled` when the caller cancels.
    public func startService(
        _ serviceName: LockdownServiceName,
        escrowBag: Data? = nil
    ) async throws(RorkDeviceError) -> DeviceConnection {
        try await withRorkDeviceError {
            try await startService(
                named: serviceName.rawValue,
                escrowBag: escrowBag
            )
        }
    }

    /// Opens a device service by its raw Lockdown identifier.
    ///
    /// Lockdown-backed sessions ask lockdownd to start the named service and
    /// upgrade the returned connection when required. RSD-backed sessions look
    /// up either the exact name or its `.shim.remote` variant, connect to the
    /// advertised port, and complete RSD check-in before returning.
    ///
    /// - Parameters:
    ///   - serviceName: Raw Lockdown service identifier. RSD sessions derive the
    ///     corresponding remote shim name automatically.
    ///   - escrowBag: Optional escrow material from a pairing record. Leave
    ///     this as `nil` unless the specific service flow requires escrow.
    /// - Returns: A connected byte stream ready for the service-specific
    ///   protocol client.
    /// - Throws: The method throws `RorkDeviceError.lockdown` when Lockdown
    ///   rejects startup, `RorkDeviceError.secureSession` or
    ///   `RorkDeviceError.secureSessionUnsupported` when a required upgrade
    ///   fails, `RorkDeviceError.protocolViolation` for a malformed Lockdown or
    ///   RSD response, `RorkDeviceError.transport` when the connection fails, or
    ///   `RorkDeviceError.cancelled` when the caller cancels.
    public func startService(
        named serviceName: String,
        escrowBag: Data? = nil
    ) async throws(RorkDeviceError) -> DeviceConnection {
        try await withRorkDeviceError {
            try await backend.startService(
                named: serviceName,
                escrowBag: escrowBag
            )
        }
    }

    /// Opens CoreDevice's raw IPv6 packet tunnel through this Lockdown session.
    ///
    /// The device must expose the internal CoreDeviceProxy service, which is
    /// available on current developer-enabled iOS versions. The returned tunnel
    /// owns its service connection and must remain alive while its negotiated
    /// network link is in use.
    ///
    /// - Parameter requestedMaximumTransmissionUnit: Largest complete IPv6
    ///   packet size requested during tunnel negotiation. The default is IPv6's
    ///   required minimum link MTU and is compatible with USB Lockdown tunnels.
    /// - Returns: Negotiated packet tunnel to the connected device.
    /// - Throws: A `RorkDeviceError` for Lockdown, transport, or CDTunnel
    ///   protocol failure.
    public func openCoreDeviceTunnel(
        requestedMaximumTransmissionUnit: UInt16 = 4_000
    ) async throws(RorkDeviceError) -> CoreDeviceTunnel {
        try await withRorkDeviceError {
            let connection = try await startService(.coreDeviceProxy)
            do {
                return try await CoreDeviceTunnel.open(
                    over: connection,
                    requestedMaximumTransmissionUnit:
                        requestedMaximumTransmissionUnit
                )
            } catch {
                connection.close()
                throw error
            }
        }
    }

    /// Reads and installs a provisioning profile through MISAgent.
    ///
    /// - Parameter fileURL: Local path to a `.mobileprovision` payload.
    /// - Throws: `RorkDeviceError.fileSystem` when the local profile cannot be
    ///   read, or another `RorkDeviceError` when installation fails.
    public func installProvisioningProfile(
        contentsOf fileURL: URL
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw RorkDeviceError.fileSystem(
                    path: fileURL.path,
                    reason: error.localizedDescription
                )
            }
            try await installProvisioningProfile(data)
        }
    }

    /// Installs a provisioning profile through MISAgent.
    ///
    /// The profile data should be the original CMS-wrapped
    /// `.mobileprovision` contents, not the decoded plist payload.
    ///
    /// - Parameter profile: Raw provisioning profile data.
    /// - Throws: `RorkDeviceError.misagentStatus` when the device rejects the
    ///   profile, or another `RorkDeviceError` for service failure.
    public func installProvisioningProfile(
        _ profile: Data
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            try await withTransientService(.misagent) { connection in
                try await MISAgentClient(
                    connection: connection
                ).installProvisioningProfile(profile)
            }
        }
    }

    /// Removes a provisioning profile through MISAgent.
    ///
    /// The identifier is the profile UUID reported by provisioning-profile
    /// tools and by decoded `.mobileprovision` payloads. This helper opens a
    /// fresh MISAgent service connection for the operation.
    ///
    /// - Parameter identifier: Provisioning profile UUID to remove.
    /// - Throws: `RorkDeviceError.misagentStatus` when the device rejects the
    ///   request, or another `RorkDeviceError` for service failure.
    public func removeProvisioningProfile(
        identifier: String
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            try await withTransientService(.misagent) { connection in
                try await MISAgentClient(
                    connection: connection
                ).removeProvisioningProfile(
                    identifier: identifier
                )
            }
        }
    }

    /// Copies installed provisioning-profile payloads through MISAgent.
    ///
    /// The returned values are the original CMS-wrapped profile bytes. Callers
    /// can write them to disk, pass them to a signing/profile parser, or inspect
    /// them with their own tooling.
    ///
    /// - Parameter mode: MISAgent copy command variant. Defaults to `.all`,
    ///   which is correct for iOS 9.3 and newer.
    /// - Returns: Raw `.mobileprovision` payloads installed on the device.
    /// - Throws: `RorkDeviceError.misagentStatus` when the device rejects the
    ///   request, or another `RorkDeviceError` for service failure.
    public func copyProvisioningProfiles(
        mode: ProvisioningProfileCopyMode = .all
    ) async throws(RorkDeviceError) -> [Data] {
        try await withRorkDeviceError {
            try await withTransientService(.misagent) { connection in
                try await MISAgentClient(
                    connection: connection
                ).copyProvisioningProfiles(mode: mode)
            }
        }
    }

    /// Starts a heartbeat responder and waits for the first device message.
    ///
    /// Some network/tunnel-backed device sessions require an active heartbeat
    /// connection before other service streams remain usable. The returned
    /// handle keeps responding until callers stop it or release it.
    ///
    /// - Parameter firstMessageTimeout: Maximum time to wait for the first device
    ///   heartbeat message.
    /// - Returns: A handle that owns the heartbeat connection.
    /// - Throws: `RorkDeviceError.heartbeat` when startup times out or returns
    ///   malformed data, or another `RorkDeviceError` for service failure.
    public func startHeartbeat(
        firstMessageTimeout: Duration = .seconds(12)
    ) async throws(RorkDeviceError) -> DeviceHeartbeat {
        try await withRorkDeviceError {
            let connection = try await startService(.heartbeat)
            let client = HeartbeatClient(connection: connection)
            let heartbeat = DeviceHeartbeat(client: client)
            do {
                try await heartbeat.start(
                    firstMessageTimeout: firstMessageTimeout
                )
                return heartbeat
            } catch {
                connection.close()
                throw error
            }
        }
    }

    /// Lists installed applications through the active session backend.
    ///
    /// Both Lockdown and Remote Service Discovery sessions use
    /// InstallationProxy. RSD-backed sessions open its advertised shim, so app
    /// inventory remains available when the Developer Disk Image is not
    /// mounted and CoreDevice's app service is absent.
    ///
    /// - Parameter type: Application class to browse. Defaults to user apps.
    /// - Returns: Typed application metadata values.
    /// - Throws: `RorkDeviceError.installationProxy` when the device rejects
    ///   the browse request, or another `RorkDeviceError` for service failure.
    public func installedApplications(
        matching type: ApplicationType = .user
    ) async throws(RorkDeviceError) -> [InstalledApplication] {
        try await withRorkDeviceError {
            try await withTransientService(.installationProxy) { connection in
                try await InstallationProxyClient(
                    connection: connection
                ).applications(matching: type)
            }
        }
    }

    /// Lists raw InstallationProxy application dictionaries.
    ///
    /// Use this escape hatch when a workflow needs fields not yet modeled by
    /// `InstalledApplication`.
    ///
    /// - Parameter type: Application class to browse. Defaults to user apps.
    /// - Returns: Raw application dictionaries returned by the device.
    /// - Throws: `RorkDeviceError.installationProxy` when the device rejects
    ///   the browse request, or another `RorkDeviceError` for service failure.
    public func rawApplications(
        matching type: ApplicationType = .user
    ) async throws(RorkDeviceError) -> [[String: Any]] {
        try await withRorkDeviceError {
            try await withTransientService(.installationProxy) { connection in
                try await InstallationProxyClient(
                    connection: connection
                ).rawApplications(matching: type)
            }
        }
    }

    /// Launches an installed application through CoreDevice's app service.
    ///
    /// This operation requires an RSD-backed session because the app service is
    /// advertised directly inside the active CoreDevice tunnel. Lockdown-only
    /// sessions fail with a protocol error instead of silently selecting a
    /// different process-control implementation.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier of the installed application.
    ///   - options: Arguments, environment, and existing-process behavior.
    /// - Returns: Positive process identifier assigned by iOS.
    /// - Throws: `RorkDeviceError.invalidInput` for an empty identifier, or
    ///   another `RorkDeviceError` when the app service cannot launch the app.
    @discardableResult
    public func launchApplication(
        bundleIdentifier: String,
        options: ApplicationLaunchOptions = ApplicationLaunchOptions()
    ) async throws(RorkDeviceError) -> Int {
        try await withRorkDeviceError {
            let bundleIdentifier = bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !bundleIdentifier.isEmpty else {
                throw RorkDeviceError.invalidInput(
                    "Application bundle identifier must not be empty."
                )
            }

            let service = try await openCoreDeviceApplicationService()
            defer {
                service.close()
            }
            return try await service.launchApplication(
                bundleIdentifier: bundleIdentifier,
                options: options
            )
        }
    }

    /// Terminates running processes belonging to an installed application.
    ///
    /// CoreDevice supplies both the installed bundle path and live process
    /// executable paths. Processes whose executables reside inside the selected
    /// bundle receive `SIGKILL`, matching the behavior expected by in-place app
    /// updates while resolving both sides of the comparison through one service.
    ///
    /// - Parameter bundleIdentifier: Bundle identifier of the installed app.
    /// - Returns: `true` when at least one matching process was terminated, or
    ///   `false` when the application was installed but not running.
    /// - Throws: `RorkDeviceError.invalidInput` when the identifier is empty or
    ///   the app is absent, or another `RorkDeviceError` for app-service failure.
    @discardableResult
    public func terminateApplication(
        bundleIdentifier: String
    ) async throws(RorkDeviceError) -> Bool {
        try await withRorkDeviceError {
            let bundleIdentifier = bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !bundleIdentifier.isEmpty else {
                throw RorkDeviceError.invalidInput(
                    "Application bundle identifier must not be empty."
                )
            }

            let applications: [CoreDeviceApplication]
            let applicationService = try await openCoreDeviceApplicationService()
            do {
                defer {
                    applicationService.close()
                }
                applications = try await applicationService.applications(
                    matching: .all
                )
            }
            guard let application = applications.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) else {
                throw RorkDeviceError.invalidInput(
                    "Application \(bundleIdentifier) is not installed."
                )
            }
            let bundlePath = standardizedDeviceFilePath(
                application.bundlePath
            )
            let executablePrefix = bundlePath.hasSuffix("/")
                ? bundlePath
                : "\(bundlePath)/"
            let runningProcesses: [CoreDeviceProcess]
            let processService = try await openCoreDeviceApplicationService()
            do {
                defer {
                    processService.close()
                }
                runningProcesses = try await processService.runningProcesses()
            }
            let processes = runningProcesses.filter {
                let executablePath = standardizedDeviceFilePath(
                    $0.executablePath
                )
                return executablePath == bundlePath
                    || executablePath.hasPrefix(executablePrefix)
            }

            // A device may close an app-service stream after a process-control
            // invocation. Isolating each signal prevents that lifecycle from
            // cancelling signals for other processes in the same application.
            for process in processes {
                let signalService =
                    try await openCoreDeviceApplicationService()
                do {
                    defer {
                        signalService.close()
                    }
                    try await signalService.sendSignal(
                        9,
                        to: process.identifier
                    )
                }
            }
            return !processes.isEmpty
        }
    }

    /// Uninstalls an application through InstallationProxy.
    ///
    /// The progress closure receives every status plist emitted by the device.
    /// The method returns after InstallationProxy reports `Complete`.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to uninstall.
    ///   - progress: Optional progress/event callback.
    /// - Throws: `RorkDeviceError.installationProxy` when the device rejects
    ///   the uninstall, or another `RorkDeviceError` for service failure.
    public func uninstallApplication(
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            try await withTransientService(.installationProxy) { connection in
                try await InstallationProxyClient(
                    connection: connection
                ).uninstall(
                    bundleIdentifier: bundleIdentifier,
                    progress: progress
                )
            }
        }
    }

    /// Stages and installs an IPA through the device services used by iOS.
    ///
    /// This combines two lower-level operations: upload the IPA to
    /// `./PublicStaging` through AFC, then ask InstallationProxy to install that
    /// staged package path.
    ///
    /// - Parameters:
    ///   - fileURL: Local path to the IPA archive.
    ///   - bundleIdentifier: Expected application bundle identifier. The value
    ///     is forwarded in InstallationProxy client options when supplied.
    ///   - progress: Optional callback for InstallationProxy status events.
    /// - Throws: `RorkDeviceError.fileSystem` when the IPA cannot be read,
    ///   `RorkDeviceError.installationProxy` when installation is rejected, or
    ///   another `RorkDeviceError` for AFC or service failure.
    public func installApplication(
        at fileURL: URL,
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            let stagedPath = try await stageApplication(
                at: fileURL,
                bundleIdentifier: bundleIdentifier
            )
            try await withTransientService(.installationProxy) { connection in
                try await InstallationProxyClient(
                    connection: connection
                ).install(
                    packagePath: stagedPath,
                    bundleIdentifier: bundleIdentifier,
                    progress: progress
                )
            }
        }
    }

    /// Stages and installs in-memory IPA data through AFC and InstallationProxy.
    ///
    /// This is equivalent to `installApplication(at:bundleIdentifier:)`
    /// except the IPA bytes are supplied directly by the caller.
    ///
    /// - Parameters:
    ///   - ipaData: IPA archive bytes.
    ///   - bundleIdentifier: Expected application bundle identifier. The value
    ///     is forwarded in InstallationProxy client options when supplied.
    ///   - progress: Optional callback for InstallationProxy status events.
    /// - Throws: `RorkDeviceError.installationProxy` when installation is
    ///   rejected, or another `RorkDeviceError` for AFC or service failure.
    public func installApplication(
        _ ipaData: Data,
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws(RorkDeviceError) {
        try await withRorkDeviceError {
            let stagedPath = try await stageApplication(
                ipaData,
                bundleIdentifier: bundleIdentifier
            )
            try await withTransientService(.installationProxy) { connection in
                try await InstallationProxyClient(
                    connection: connection
                ).install(
                    packagePath: stagedPath,
                    bundleIdentifier: bundleIdentifier,
                    progress: progress
                )
            }
        }
    }

    /// Uploads an IPA to AFC public staging and returns the device path.
    ///
    /// Call this when you want to separate staging from installation, for
    /// example to inspect the staged path or reuse a custom
    /// `InstallationProxyClient` command.
    ///
    /// - Parameters:
    ///   - fileURL: This local IPA archive is uploaded.
    ///   - bundleIdentifier: This identifier names the staged archive.
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    /// - Throws: `RorkDeviceError.fileSystem` when the IPA cannot be read, or
    ///   another `RorkDeviceError` for AFC or service failure.
    public func stageApplication(
        at fileURL: URL,
        bundleIdentifier: String
    ) async throws(RorkDeviceError) -> String {
        try await withRorkDeviceError {
            try await withTransientService(.afc) { connection in
                try await AFCClient(
                    connection: connection
                ).uploadIPA(
                    at: fileURL,
                    bundleIdentifier: bundleIdentifier
                )
            }
        }
    }

    /// Uploads in-memory IPA data to AFC public staging.
    ///
    /// - Parameters:
    ///   - ipaData: IPA archive bytes.
    ///   - bundleIdentifier: Bundle identifier used to name the staged IPA.
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    /// - Throws: A `RorkDeviceError` when AFC staging or its service fails.
    public func stageApplication(
        _ ipaData: Data,
        bundleIdentifier: String
    ) async throws(RorkDeviceError) -> String {
        try await withRorkDeviceError {
            try await withTransientService(.afc) { connection in
                try await AFCClient(
                    connection: connection
                ).uploadIPA(
                    ipaData,
                    bundleIdentifier: bundleIdentifier
                )
            }
        }
    }

    /// Opens the default AFC service for device-level file operations.
    ///
    /// The root exposed by default AFC depends on device policy and pairing
    /// state. For application-specific files, prefer
    /// `openApplicationContainer(bundleIdentifier:scope:)`.
    ///
    /// The returned client owns its service connection. Call `close()` when
    /// device file access is complete.
    ///
    /// - Returns: AFC client rooted at the default AFC service.
    /// - Throws: A `RorkDeviceError` when the AFC service cannot be opened.
    public func openAFC() async throws(RorkDeviceError) -> AFCClient {
        try await withRorkDeviceError {
            let connection = try await startService(.afc)
            return AFCClient(connection: connection)
        }
    }

    /// Opens AFC access to an installed application's HouseArrest area.
    ///
    /// HouseArrest is useful for document browser tools, diagnostics, and
    /// backup-style workflows that need files from one app rather than the
    /// device-wide AFC root.
    ///
    /// The returned client owns the vended service connection. Call `close()`
    /// when container access is complete.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Installed application bundle identifier.
    ///   - scope: Application area requested from HouseArrest.
    /// - Returns: AFC client rooted at the requested app area.
    /// - Throws: `RorkDeviceError.protocolViolation` when HouseArrest rejects
    ///   the request, or another `RorkDeviceError` for service failure.
    public func openApplicationContainer(
        bundleIdentifier: String,
        scope: HouseArrestScope = .documents
    ) async throws(RorkDeviceError) -> AFCClient {
        try await withRorkDeviceError {
            let connection = try await startService(.houseArrest)
            let client = HouseArrestClient(connection: connection)
            do {
                return try await client.openApplicationContainer(
                    bundleIdentifier: bundleIdentifier,
                    scope: scope
                )
            } catch {
                connection.close()
                throw error
            }
        }
    }

    /// Closes a short-lived service after its operation returns or throws.
    ///
    /// This helper is reserved for operations that do not return a live client.
    /// Returning the connection or an object that owns it would violate the
    /// caller's ownership contract because `defer` closes it before return.
    ///
    /// - Parameters:
    ///   - serviceName: This modeled service is opened for one operation.
    ///   - operation: This work completes before the connection is closed.
    /// - Returns: The operation produces a value that owns no live service.
    /// - Throws: The method propagates failure after closing the connection.
    private func withTransientService<Result>(
        _ serviceName: LockdownServiceName,
        operation: (DeviceConnection) async throws -> Result
    ) async throws -> Result {
        let connection = try await startService(serviceName)
        defer {
            connection.close()
        }
        return try await operation(connection)
    }

    /// Opens CoreDevice's direct RemoteXPC app service on an RSD session.
    ///
    /// The backend returns a raw stream because direct CoreDevice services must
    /// not receive the property-list check-in used by Lockdown-compatible shim
    /// services.
    ///
    /// A successful result owns the service connection. A failed RemoteXPC
    /// handshake closes the raw stream before propagating its error.
    ///
    /// - Returns: The result owns a connected CoreDevice application service.
    /// - Throws: The method propagates lookup, transport, or handshake failure.
    private func openCoreDeviceApplicationService() async throws -> CoreDeviceApplicationService {
        let connection = try await backend.startRemoteService(
            named: CoreDeviceApplicationService.serviceName
        )
        do {
            return try await CoreDeviceApplicationService.open(
                over: connection
            )
        } catch {
            connection.close()
            throw error
        }
    }
}

/// Converts CoreDevice file locations into comparable absolute paths.
///
/// Installed-application records use POSIX paths, while process records may
/// encode the same location as a percent-escaped `file:` URL. Interpreting a
/// file URL as a literal path preserves its scheme and escapes, so an
/// executable inside an application bundle would not match that bundle.
///
/// - Parameter value: Absolute POSIX path or file URL reported by CoreDevice.
/// - Returns: Standardized file-system path with file-URL escapes decoded.
private func standardizedDeviceFilePath(_ value: String) -> String {
    if let url = URL(string: value), url.isFileURL {
        return url.standardizedFileURL.path
    }
    return URL(fileURLWithPath: value).standardizedFileURL.path
}

/// Lockdown services exposed by the high-level install workflow.
public enum LockdownServiceName: String, Sendable {
    /// Apple File Conduit, used to create `./PublicStaging` and upload IPA data.
    case afc = "com.apple.afc"

    /// CoreDevice packet proxy used to negotiate a private IPv6 link.
    case coreDeviceProxy =
        "com.apple.internal.devicecompute.CoreDeviceProxy"

    /// AMFI service used to reveal the Developer Mode setting.
    case developerMode = "com.apple.amfi.lockdown"

    /// Device heartbeat service, used to keep tunnel-backed sessions alive.
    case heartbeat = "com.apple.mobile.heartbeat"

    /// HouseArrest, used to vend app documents and containers through AFC.
    case houseArrest = "com.apple.mobile.house_arrest"

    /// InstallationProxy, used to browse, install, and uninstall applications.
    case installationProxy = "com.apple.mobile.installation_proxy"

    /// MISAgent, used to install and remove provisioning profiles.
    case misagent = "com.apple.misagent"
}
