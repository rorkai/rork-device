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
}
