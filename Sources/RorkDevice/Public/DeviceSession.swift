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
    public func deviceInfo() async throws -> DeviceInfo {
        let values = try await lockdown.getValue(domain: nil, key: nil)
        guard let dictionary = values as? [String: Any] else {
            throw RorkDeviceError.protocolViolation("Lockdown GetValue did not return a dictionary.")
        }
        return DeviceInfo(values: dictionary)
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
    /// - Parameter url: Local path to a `.mobileprovision` payload.
    public func installProvisioningProfile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
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

    /// Lists applications through InstallationProxy.
    ///
    /// - Parameter type: Application class to browse. Defaults to user apps.
    /// - Returns: Raw application dictionaries returned by the device.
    public func applications(type: ApplicationType = .user) async throws -> [[String: Any]] {
        let connection = try await startService(.installationProxy)
        let client = InstallationProxyClient(connection: connection)
        return try await client.browse(applicationType: type)
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
    ///   - ipaURL: Local path to the IPA archive.
    ///   - bundleIdentifier: Expected application bundle identifier. The value
    ///     is forwarded in InstallationProxy client options when supplied.
    ///   - progress: Optional callback for InstallationProxy status events.
    public func installApplication(
        ipaURL: URL,
        bundleIdentifier: String,
        progress: InstallationProgressHandler? = nil
    ) async throws {
        let stagedPath = try await stageApplication(ipaURL: ipaURL, bundleIdentifier: bundleIdentifier)
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
    public func stageApplication(ipaURL: URL, bundleIdentifier: String) async throws -> String {
        let connection = try await startService(.afc)
        let afc = AFCClient(connection: connection)
        return try await afc.uploadIPA(at: ipaURL, bundleIdentifier: bundleIdentifier)
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
