import Foundation

/// Client for the `com.apple.misagent` provisioning-profile service.
///
/// MISAgent installs and removes provisioning profiles on a paired device. This
/// client operates on the raw service protocol; use `DeviceSession` for the
/// higher-level install flow.
public final class MISAgentClient {
    private let connection: DeviceConnection

    /// Creates a MISAgent client over an existing service connection.
    ///
    /// The connection should come from `DeviceSession.startService(.misagent)`
    /// or an equivalent transport that has already handled service security.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Installs a provisioning profile.
    ///
    /// The payload must be the original CMS-wrapped `.mobileprovision` bytes.
    /// Passing the decoded profile plist is not equivalent and will be rejected
    /// by the device.
    public func installProvisioningProfile(_ profile: Data) async throws {
        try await PropertyListMessageFramer.send([
            "MessageType": "Install",
            "Profile": profile,
            "ProfileType": "Provisioning",
        ], to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)
        let status = response.int("Status") ?? -1
        guard status == 0 else {
            throw RorkDeviceError.misagentStatus(status)
        }
    }

    /// Removes a provisioning profile by UUID.
    ///
    /// - Parameter identifier: Profile UUID as stored by the device.
    public func removeProvisioningProfile(identifier: String) async throws {
        try await PropertyListMessageFramer.send([
            "MessageType": "Remove",
            "ProfileID": identifier,
            "ProfileType": "Provisioning",
        ], to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)
        let status = response.int("Status") ?? -1
        guard status == 0 else {
            throw RorkDeviceError.misagentStatus(status)
        }
    }

    /// Copies installed provisioning-profile payloads from the device.
    ///
    /// MISAgent returns CMS-wrapped `.mobileprovision` bytes, not decoded plist
    /// dictionaries. Keeping the raw payloads lets callers choose their own
    /// profile parser while preserving the exact data needed for backups,
    /// diagnostics, or later removal decisions.
    ///
    /// - Parameter mode: MISAgent copy command variant. `.all` is the modern
    ///   default for iOS 9.3 and newer; `.legacy` exists for older devices.
    /// - Returns: Raw provisioning-profile payloads returned by the device.
    public func copyProvisioningProfiles(mode: ProvisioningProfileCopyMode = .all) async throws -> [Data] {
        try await PropertyListMessageFramer.send([
            "MessageType": mode.messageType,
            "ProfileType": "Provisioning",
        ], to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)
        let status = response.int("Status") ?? -1
        guard status == 0 else {
            throw RorkDeviceError.misagentStatus(status)
        }

        guard let payload = response["Payload"] as? [Data] else {
            throw RorkDeviceError.protocolViolation("MISAgent Copy response did not include provisioning profile data.")
        }
        return payload
    }
}

/// MISAgent copy command variant used when reading installed profiles.
public enum ProvisioningProfileCopyMode: Sendable {
    /// `CopyAll`, the command used by iOS 9.3 and newer.
    case all

    /// `Copy`, the command used by iOS 9.2.1 and older.
    case legacy

    /// Protocol message name sent to MISAgent.
    var messageType: String {
        switch self {
        case .all:
            return "CopyAll"
        case .legacy:
            return "Copy"
        }
    }
}
