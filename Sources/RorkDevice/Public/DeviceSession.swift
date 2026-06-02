import Foundation

/// Authenticated device session with helpers for developer-service workflows.
///
/// A session is created after Lockdown accepts a pairing record. It keeps the
/// authenticated Lockdown client plus the transport needed to open additional
/// services on the same device. The high-level methods here implement the
/// 0.1.0 app-install vertical slice:
///
/// - query device information through Lockdown,
/// - install provisioning profiles through MISAgent,
/// - stage IPA archives through AFC,
/// - list, install, and uninstall apps through InstallationProxy.
///
/// `DeviceSession` does not own pairing creation. Callers must provide a valid
/// pairing record when opening the session through `DeviceClient`.
public final class DeviceSession {
    private let transport: DeviceTransport
    private let lockdown: LockdownClient
    private let pairingRecord: PairingRecord
    private let label: String
    private let secureSessionUpgrader: SecureSessionUpgrader

    init(
        transport: DeviceTransport,
        lockdown: LockdownClient,
        pairingRecord: PairingRecord,
        label: String,
        secureSessionUpgrader: SecureSessionUpgrader
    ) {
        self.transport = transport
        self.lockdown = lockdown
        self.pairingRecord = pairingRecord
        self.label = label
        self.secureSessionUpgrader = secureSessionUpgrader
    }

    /// Queries the default Lockdown value domain and returns common fields.
    ///
    /// Use this as a lightweight readiness check after opening a session. More
    /// specialized Lockdown values can be queried through `LockdownClient`
    /// directly when needed.
    ///
    /// - Returns: Common identity and OS fields from Lockdown.
    /// - Throws: `RorkDeviceError.protocolViolation` when the response does
    ///   not contain a dictionary, plus lower-level transport errors.
    public func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: try await lockdown.deviceValues())
    }

    /// Starts a supported Lockdown service and opens its service connection.
    ///
    /// If Lockdown marks the service as secure, this method upgrades the
    /// returned service connection using the same `SecureSessionUpgrader` that
    /// was configured for the session.
    ///
    /// - Parameter serviceName: Service needed by the app-install workflow.
    /// - Returns: A connected byte stream ready for the service-specific
    ///   protocol client.
    public func startService(_ serviceName: LockdownServiceName) async throws -> DeviceConnection {
        let service = try await lockdown.startService(serviceName.rawValue)
        var connection = try await transport.connect(to: service.port)
        if service.requiresSecureConnection {
            connection = try await secureSessionUpgrader.upgrade(connection, pairingRecord: pairingRecord)
        }
        return connection
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

    /// Lists installed applications through InstallationProxy.
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
    /// `/PublicStaging` through AFC, then ask InstallationProxy to install that
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
}

/// Lockdown services exposed by the high-level 0.1.0 install workflow.
public enum LockdownServiceName: String, Sendable {
    /// Apple File Conduit, used to create `/PublicStaging` and upload IPA data.
    case afc = "com.apple.afc"

    /// InstallationProxy, used to browse, install, and uninstall applications.
    case installationProxy = "com.apple.mobile.installation_proxy"

    /// MISAgent, used to install and remove provisioning profiles.
    case misagent = "com.apple.misagent"
}
