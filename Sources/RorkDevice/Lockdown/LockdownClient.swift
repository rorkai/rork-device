import Foundation

/// Low-level client for the Lockdown plist protocol.
///
/// Lockdown is the device service used to authenticate a paired host, read
/// device values, and start other services. Most applications should prefer
/// `DeviceClient` and `DeviceSession`; use `LockdownClient` directly when you
/// need custom Lockdown requests or protocol tests.
public final class LockdownClient {
    private let connection: DeviceConnection
    private let label: String

    /// Creates a Lockdown client over an existing Lockdown connection.
    ///
    /// The connection must already point at the Lockdown port. This initializer
    /// does not take ownership of discovery, pairing lookup, or secure-session
    /// upgrade.
    ///
    /// - Parameters:
    ///   - connection: Byte stream connected to Lockdown.
    ///   - label: Client label included in requests for device-side logs.
    public init(connection: DeviceConnection, label: String = "rorkdevice") {
        self.connection = connection
        self.label = label
    }

    /// Starts a Lockdown session using an existing pairing record.
    ///
    /// This sends `HostID` and `SystemBUID` from the record. If the response
    /// sets `EnableSessionSSL`, callers must upgrade the connection before
    /// issuing further Lockdown requests.
    ///
    /// - Returns: Session metadata, including whether secure traffic is
    ///   required.
    public func startSession(pairingRecord: PairingRecord) async throws -> LockdownSessionStart {
        let response = try await request([
            "Label": label,
            "Request": "StartSession",
            "HostID": pairingRecord.hostID,
            "SystemBUID": pairingRecord.systemBUID,
        ])
        try checkResult(response, request: "StartSession")
        return LockdownSessionStart(
            sessionID: response.string("SessionID"),
            requiresSecureConnection: response.bool("EnableSessionSSL") ?? false
        )
    }

    /// Queries a Lockdown value by optional domain and key.
    ///
    /// Passing `nil` for both arguments requests the default top-level device
    /// information dictionary. Domain/key values are sent as-is so callers can
    /// use newer device domains without waiting for wrapper APIs.
    ///
    /// - Returns: The decoded plist value from the `Value` field.
    public func getValue(domain: String?, key: String?) async throws -> Any {
        var request: [String: Any] = [
            "Label": label,
            "Request": "GetValue",
        ]
        if let domain {
            request["Domain"] = domain
        }
        if let key {
            request["Key"] = key
        }

        let response = try await self.request(request)
        try checkResult(response, request: "GetValue")
        guard let value = response["Value"] else {
            throw RorkDeviceError.protocolViolation("Lockdown GetValue response is missing Value.")
        }
        return value
    }

    /// Starts a Lockdown service and returns its port descriptor.
    ///
    /// After a successful response, open a new transport connection to the
    /// returned port. If `requiresSecureConnection` is true, upgrade that
    /// service connection before speaking the service protocol.
    public func startService(_ serviceName: String) async throws -> LockdownService {
        let response = try await request([
            "Label": label,
            "Request": "StartService",
            "Service": serviceName,
        ])
        try checkResult(response, request: "StartService")
        guard let port = response.int("Port") else {
            throw RorkDeviceError.protocolViolation("Lockdown StartService response is missing Port.")
        }
        return LockdownService(
            name: serviceName,
            port: UInt16(port),
            requiresSecureConnection: response.bool("EnableServiceSSL") ?? false
        )
    }

    /// Sends one Lockdown request and returns its decoded response dictionary.
    private func request(_ dictionary: [String: Any]) async throws -> [String: Any] {
        try await PropertyListMessageFramer.send(dictionary, to: connection)
        return try await PropertyListMessageFramer.receive(from: connection)
    }
}

/// Result of a Lockdown `StartSession` request.
public struct LockdownSessionStart: Equatable, Sendable {
    /// Session identifier returned by the device, when present.
    public let sessionID: String?

    /// Whether subsequent Lockdown traffic must be sent through a secure
    /// connection.
    public let requiresSecureConnection: Bool
}

/// Descriptor returned by Lockdown after starting a device service.
public struct LockdownService: Equatable, Sendable {
    /// Service name requested from Lockdown.
    public let name: String

    /// Device-side TCP port for the service.
    public let port: UInt16

    /// Whether this service requires a secure connection before protocol data
    /// is exchanged.
    public let requiresSecureConnection: Bool
}

/// Validates common Lockdown `Result` and `Error` fields.
func checkResult(_ response: [String: Any], request: String) throws {
    if let result = response.string("Result"), result != "Success" {
        let error = response.string("Error") ?? result
        throw RorkDeviceError.lockdown("\(request) failed: \(error)")
    }
    if let error = response.string("Error") {
        throw RorkDeviceError.lockdown("\(request) failed: \(error)")
    }
}
