import Foundation

/// Client for the HouseArrest service.
///
/// HouseArrest grants AFC access to an installed application's container or
/// documents area. The service starts as a plist protocol: callers ask the
/// device to vend a specific application area, then the same connection becomes
/// an AFC stream when the device replies with `Complete`.
///
/// A successful vend consumes the connection. Create a new `HouseArrestClient`
/// over a fresh service connection for each container you want to open.
public final class HouseArrestClient {
    private let connection: DeviceConnection
    private let stateLock = NSLock()
    private var state = HouseArrestClientState.idle

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
        try beginVend()
        let request = [
            "Command": scope.command,
            "Identifier": bundleIdentifier,
        ]
        do {
            try await PropertyListMessageFramer.send(request, to: connection)
            let response = try await PropertyListMessageFramer.receive(from: connection)
            try validateHouseArrestResponse(response)
            finishVend()
            return AFCClient(connection: connection)
        } catch {
            failVend()
            throw error
        }
    }

    /// Reserves the plist connection for a single vend request.
    private func beginVend() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state == .idle else {
            throw RorkDeviceError.protocolViolation(
                "HouseArrestClient cannot vend more than one container per connection."
            )
        }
        state = .vending
    }

    /// Marks the connection as permanently handed over to AFC.
    private func finishVend() {
        stateLock.lock()
        state = .vended
        stateLock.unlock()
    }

    /// Restores the client after a failed plist-stage request.
    private func failVend() {
        stateLock.lock()
        state = .idle
        stateLock.unlock()
    }
}

/// Internal HouseArrest connection state.
private enum HouseArrestClientState {
    case idle
    case vending
    case vended
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
