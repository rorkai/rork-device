import Foundation

/// Client for the HouseArrest service.
///
/// HouseArrest grants AFC access to an installed application's container or
/// documents area. The service starts as a plist protocol: callers ask the
/// device to vend a specific application area, then the same connection becomes
/// an AFC stream when the device replies with `Complete`.
public final class HouseArrestClient {
    private let connection: DeviceConnection

    /// Creates a HouseArrest client over an existing service connection.
    ///
    /// The connection should come from
    /// `DeviceSession.startService(.houseArrest)`.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Opens AFC access for an installed application's container.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Application bundle identifier.
    ///   - scope: Container area requested from the device.
    /// - Returns: AFC client backed by the same HouseArrest service connection.
    public func openApplicationContainer(
        bundleIdentifier: String,
        scope: HouseArrestScope = .documents
    ) async throws -> AFCClient {
        let request = [
            "Command": scope.command,
            "Identifier": bundleIdentifier,
        ]
        try await PropertyListMessageFramer.send(request, to: connection)
        let response = try await PropertyListMessageFramer.receive(from: connection)
        try validateHouseArrestResponse(response)
        return AFCClient(connection: connection)
    }
}

/// HouseArrest application area to vend through AFC.
public enum HouseArrestScope: String, Equatable, Sendable, CaseIterable {
    /// Application documents area.
    case documents

    /// Full application container, when the device permits it.
    case container

    /// HouseArrest command string sent to the device.
    var command: String {
        switch self {
        case .documents:
            return "VendDocuments"
        case .container:
            return "VendContainer"
        }
    }
}

/// Validates the plist response returned before HouseArrest switches to AFC.
private func validateHouseArrestResponse(_ response: [String: Any]) throws {
    if response["Status"] as? String == "Complete" {
        return
    }
    if let error = response["Error"] as? String {
        let description = response["ErrorDescription"] as? String
        if let description, !description.isEmpty {
            throw RorkDeviceError.protocolViolation("HouseArrest failed: \(error): \(description)")
        }
        throw RorkDeviceError.protocolViolation("HouseArrest failed: \(error)")
    }
    throw RorkDeviceError.protocolViolation("HouseArrest did not complete.")
}
