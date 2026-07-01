import Foundation

/// Connected device service environment for installation and diagnostics.
///
/// A session hides how service endpoints are discovered. Lockdown-backed
/// sessions start services through an authenticated Lockdown connection, while
/// remote sessions connect to ports advertised by Remote Service Discovery and
/// complete the required RSD check-in. The higher-level AFC, MISAgent,
/// heartbeat, HouseArrest, and InstallationProxy workflows are identical for
/// both routes.
///
/// Each operation opens the service connection it needs. Callers may therefore
/// retain a session for a complete install workflow without managing individual
/// service ports or protocol handshakes.
public final class DeviceSession {
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
    /// - Throws: A transport or protocol error when the backend cannot obtain
    ///   valid device information.
    public func fetchDeviceInfo() async throws -> DeviceInfo {
        try await backend.fetchDeviceInfo()
    }

    /// Returns whether Developer Mode is enabled on the connected device.
    ///
    /// The query reads the AMFI Lockdown value used by iOS itself. It is
    /// passive and does not reveal or change the setting.
    ///
    /// - Returns: `true` when the device reports Developer Mode as enabled.
    /// - Throws: A Lockdown or transport error, or a protocol error when this
    ///   session route cannot access Lockdown value domains.
    public func isDeveloperModeEnabled() async throws -> Bool {
        try await backend.isDeveloperModeEnabled()
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
    /// - Throws: A Lockdown error when iOS rejects the setting, or a protocol
    ///   error when the session is not backed by Lockdown.
    public func enableWirelessConnections() async throws {
        try await backend.enableWirelessConnections()
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
    /// - Throws: A Lockdown error when iOS rejects the request, a protocol
    ///   violation when the service returns an incomplete response, or a
    ///   transport error when the service connection fails.
    public func revealDeveloperMode() async throws {
        let connection = try await startService(.developerMode)
        defer {
            connection.close()
        }
        try await DeveloperModeClient(
            connection: connection
        ).reveal()
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
    /// - Throws: An input error for an unsupported device, disabled Developer
    ///   Mode, or invalid image; a protocol or transport error when Lockdown,
    ///   image mounter, or Apple TSS cannot complete the operation.
    public func mountPersonalizedDeveloperDiskImage(
        from restoreDirectory: URL
    ) async throws -> DeveloperDiskImageMountResult {
        let image = try PersonalizedDeveloperDiskImage(
            contentsOf: restoreDirectory
        )
        let ecid = try await developerDiskImageECID()
        return try await mountPersonalizedDeveloperDiskImage(
            image,
            ecid: ecid
        )
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
    /// - Throws: An input error for an unsupported device, disabled Developer
    ///   Mode, invalid archive, or incompatible image; a protocol or transport
    ///   error when the archive host, Lockdown, image mounter, or Apple TSS
    ///   cannot complete the operation.
    public func mountPersonalizedDeveloperDiskImage(
        from source: DeveloperDiskImageSource,
        using store: DeveloperDiskImageStore = DeveloperDiskImageStore()
    ) async throws -> DeveloperDiskImageMountResult {
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

    /// Unmounts the personalized Developer Disk Image, if one is mounted.
    ///
    /// Developer services remain available only while an image is mounted, so
    /// this is mainly for forcing a clean re-mount; the device also clears a
    /// mounted image on reboot. The device reports its own error when nothing is
    /// mounted, so call `mountedPersonalizedDeveloperDiskImages()` first for a
    /// best-effort teardown.
    ///
    /// - Throws: A protocol or transport error when the image mounter cannot
    ///   complete the request.
    public func unmountPersonalizedDeveloperDiskImage() async throws {
        try await PersonalizedDeveloperDiskImageUnmounter(
            openConnection: {
                try await self.startService(
                    named: Self.personalizedDeveloperDiskImageServiceName
                )
            }
        ).unmount()
    }

    /// Returns the signatures of the personalized Developer Disk Images the
    /// device reports mounted.
    ///
    /// The result is empty when no personalized image is mounted, which is the
    /// expected state after a reboot.
    ///
    /// - Returns: One signature per mounted personalized image.
    /// - Throws: A protocol or transport error when the image mounter cannot
    ///   complete the request.
    public func mountedPersonalizedDeveloperDiskImages() async throws -> [Data] {
        try await PersonalizedDeveloperDiskImageLister(
            openConnection: {
                try await self.startService(
                    named: Self.personalizedDeveloperDiskImageServiceName
                )
            }
        ).mountedImageSignatures()
    }

    /// Validates device state before network or image-mounter work begins.
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
    public func startService(_ serviceName: LockdownServiceName, escrowBag: Data? = nil) async throws -> DeviceConnection {
        try await startService(named: serviceName.rawValue, escrowBag: escrowBag)
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
    /// - Throws: `RorkDeviceError.protocolViolation` when the service is absent
    ///   or its handshake is invalid, plus lower-level transport errors.
    public func startService(named serviceName: String, escrowBag: Data? = nil) async throws -> DeviceConnection {
        try await backend.startService(named: serviceName, escrowBag: escrowBag)
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
    /// - Throws: Lockdown, transport, or CDTunnel protocol errors.
    public func openCoreDeviceTunnel(
        requestedMaximumTransmissionUnit: UInt16 = 1_280
    ) async throws -> CoreDeviceTunnel {
        let connection = try await startService(.coreDeviceProxy)
        return try await CoreDeviceTunnel.open(
            over: connection,
            requestedMaximumTransmissionUnit:
                requestedMaximumTransmissionUnit
        )
    }

    /// Reads and installs a provisioning profile through MISAgent.
    ///
    /// - Parameter fileURL: Local path to a `.mobileprovision` payload.
    public func installProvisioningProfile(contentsOf fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        try await installProvisioningProfile(data)
    }

    /// Installs a provisioning profile through MISAgent.
    ///
    /// The profile data should be the original CMS-wrapped
    /// `.mobileprovision` contents, not the decoded plist payload.
    ///
    /// - Parameter profile: Raw provisioning profile data.
    public func installProvisioningProfile(_ profile: Data) async throws {
        let connection = try await startService(.misagent)
        let client = MISAgentClient(connection: connection)
        try await client.installProvisioningProfile(profile)
    }

    /// Removes a provisioning profile through MISAgent.
    ///
    /// The identifier is the profile UUID reported by provisioning-profile
    /// tools and by decoded `.mobileprovision` payloads. This helper opens a
    /// fresh MISAgent service connection for the operation.
    ///
    /// - Parameter identifier: Provisioning profile UUID to remove.
    public func removeProvisioningProfile(identifier: String) async throws {
        let connection = try await startService(.misagent)
        let client = MISAgentClient(connection: connection)
        try await client.removeProvisioningProfile(identifier: identifier)
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
    public func copyProvisioningProfiles(mode: ProvisioningProfileCopyMode = .all) async throws -> [Data] {
        let connection = try await startService(.misagent)
        let client = MISAgentClient(connection: connection)
        return try await client.copyProvisioningProfiles(mode: mode)
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
    public func startHeartbeat(firstMessageTimeout: Duration = .seconds(12)) async throws -> DeviceHeartbeat {
        let connection = try await startService(.heartbeat)
        let client = HeartbeatClient(connection: connection)
        let heartbeat = DeviceHeartbeat(client: client)
        try await heartbeat.start(firstMessageTimeout: firstMessageTimeout)
        return heartbeat
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
    public func installedApplications(matching type: ApplicationType = .user) async throws -> [InstalledApplication] {
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        return try await client.applications(matching: type)
    }

    /// Lists raw InstallationProxy application dictionaries.
    ///
    /// Use this escape hatch when a workflow needs fields not yet modeled by
    /// `InstalledApplication`.
    ///
    /// - Parameter type: Application class to browse. Defaults to user apps.
    /// - Returns: Raw application dictionaries returned by the device.
    public func rawApplications(matching type: ApplicationType = .user) async throws -> [[String: Any]] {
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        return try await client.rawApplications(matching: type)
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
    @discardableResult
    public func launchApplication(
        bundleIdentifier: String,
        options: ApplicationLaunchOptions = ApplicationLaunchOptions()
    ) async throws -> Int {
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
    @discardableResult
    public func terminateApplication(
        bundleIdentifier: String
    ) async throws -> Bool {
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
        let bundlePath = standardizedDeviceFilePath(application.bundlePath)
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
            let signalService = try await openCoreDeviceApplicationService()
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

    /// Uninstalls an application through InstallationProxy.
    ///
    /// The progress closure receives every status plist emitted by the device.
    /// The method returns after InstallationProxy reports `Complete`.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to uninstall.
    ///   - progress: Optional progress/event callback.
    public func uninstallApplication(
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        try await client.uninstall(bundleIdentifier: bundleIdentifier, progress: progress)
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
    public func installApplication(
        at fileURL: URL,
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        let stagedPath = try await stageApplication(at: fileURL, bundleIdentifier: bundleIdentifier)
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        try await client.install(packagePath: stagedPath, bundleIdentifier: bundleIdentifier, progress: progress)
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
    public func installApplication(
        _ ipaData: Data,
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        let stagedPath = try await stageApplication(ipaData, bundleIdentifier: bundleIdentifier)
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        try await client.install(packagePath: stagedPath, bundleIdentifier: bundleIdentifier, progress: progress)
    }

    /// Uploads an IPA to AFC public staging and returns the device path.
    ///
    /// Call this when you want to separate staging from installation, for
    /// example to inspect the staged path or reuse a custom
    /// `InstallationProxyClient` command.
    ///
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    public func stageApplication(at fileURL: URL, bundleIdentifier: String) async throws -> String {
        let connection = try await startService(.afc)
        let afc = AFCClient(connection: connection)
        return try await afc.uploadIPA(at: fileURL, bundleIdentifier: bundleIdentifier)
    }

    /// Uploads in-memory IPA data to AFC public staging.
    ///
    /// - Parameters:
    ///   - ipaData: IPA archive bytes.
    ///   - bundleIdentifier: Bundle identifier used to name the staged IPA.
    /// - Returns: Device path suitable for InstallationProxy `Install`.
    public func stageApplication(_ ipaData: Data, bundleIdentifier: String) async throws -> String {
        let connection = try await startService(.afc)
        let afc = AFCClient(connection: connection)
        return try await afc.uploadIPA(ipaData, bundleIdentifier: bundleIdentifier)
    }

    /// Opens the default AFC service for device-level file operations.
    ///
    /// The root exposed by default AFC depends on device policy and pairing
    /// state. For application-specific files, prefer
    /// `openApplicationContainer(bundleIdentifier:scope:)`.
    ///
    /// - Returns: AFC client rooted at the default AFC service.
    public func openAFC() async throws -> AFCClient {
        let connection = try await startService(.afc)
        return AFCClient(connection: connection)
    }

    /// Opens AFC access to an installed application's HouseArrest area.
    ///
    /// HouseArrest is useful for document browser tools, diagnostics, and
    /// backup-style workflows that need files from one app rather than the
    /// device-wide AFC root.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Installed application bundle identifier.
    ///   - scope: Application area requested from HouseArrest.
    /// - Returns: AFC client rooted at the requested app area.
    public func openApplicationContainer(
        bundleIdentifier: String,
        scope: HouseArrestScope = .documents
    ) async throws -> AFCClient {
        let connection = try await startService(.houseArrest)
        let client = HouseArrestClient(connection: connection)
        return try await client.openApplicationContainer(bundleIdentifier: bundleIdentifier, scope: scope)
    }

    /// Opens CoreDevice's direct RemoteXPC app service on an RSD session.
    ///
    /// The backend returns a raw stream because direct CoreDevice services must
    /// not receive the property-list check-in used by Lockdown-compatible shim
    /// services.
    private func openCoreDeviceApplicationService() async throws -> CoreDeviceApplicationService {
        let connection = try await backend.startRemoteService(
            named: CoreDeviceApplicationService.serviceName
        )
        return try await CoreDeviceApplicationService.open(over: connection)
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
