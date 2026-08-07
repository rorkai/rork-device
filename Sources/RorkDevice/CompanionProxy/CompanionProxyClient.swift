import Foundation

/// Client for the `com.apple.companion_proxy` service.
///
/// The service exposes devices paired through the connected iPhone and values
/// from each paired device's registry. Create the client with a connection from
/// `DeviceSession.startService(.companionProxy)`.
public final class CompanionProxyClient {
    /// Lockdown identifier used to start the companion proxy service.
    public static let serviceName = "com.apple.companion_proxy"

    /// Byte stream carrying framed companion proxy property lists.
    private let connection: DeviceConnection

    /// Creates a client over an existing companion proxy connection.
    ///
    /// The caller retains ownership of `connection` and must close it after the
    /// final request.
    public init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Returns the identifiers of devices paired through the connected phone.
    ///
    /// The service returns an empty array when no companion devices are paired.
    ///
    /// - Returns: Paired device identifiers in service-defined order.
    /// - Throws: A transport error or protocol violation when the response is
    ///   malformed.
    public func pairedDeviceIdentifiers() async throws -> [String] {
        let response = try await request([
            "Command": "GetDeviceRegistry",
        ])
        guard let values = response["PairedDevicesArray"] as? [Any] else {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy device registry response is missing PairedDevicesArray."
            )
        }

        var identifiers: [String] = []
        identifiers.reserveCapacity(values.count)
        for value in values {
            guard let identifier = value as? String,
                  !identifier.isEmpty else {
                throw RorkDeviceError.protocolViolation(
                    "Companion proxy device registry contains an invalid identifier."
                )
            }
            identifiers.append(identifier)
        }
        return identifiers
    }

    /// Reads a registry value from one paired companion device.
    ///
    /// - Parameters:
    ///   - key: Registry key to read.
    ///   - deviceIdentifier: Identifier returned by
    ///     `pairedDeviceIdentifiers()`.
    /// - Returns: The property-list value, or `nil` when the key is absent.
    /// - Throws: An input error for an empty key or identifier, plus transport
    ///   and protocol errors.
    public func value(
        forKey key: String,
        on deviceIdentifier: String
    ) async throws -> Any? {
        guard !deviceIdentifier.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Companion device identifier must not be empty."
            )
        }
        guard !key.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Companion device registry key must not be empty."
            )
        }

        let response = try await request([
            "Command": "GetValueFromRegistry",
            "GetValueGizmoUDIDKey": deviceIdentifier,
            "GetValueKeyKey": key,
        ])
        guard let values =
            response["RetrievedValueDictionary"] as? [String: Any] else {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy value response is missing RetrievedValueDictionary."
            )
        }
        return values[key]
    }

    /// Reads an optional string from one paired device's registry.
    ///
    /// - Parameters:
    ///   - key: Registry key to read.
    ///   - deviceIdentifier: Identifier returned by
    ///     `pairedDeviceIdentifiers()`.
    /// - Returns: The string value, or `nil` when the key is absent.
    /// - Throws: A protocol violation when the registry value is not a string.
    public func stringValue(
        forKey key: String,
        on deviceIdentifier: String
    ) async throws -> String? {
        guard let value = try await value(
            forKey: key,
            on: deviceIdentifier
        ) else {
            return nil
        }
        guard let string = value as? String else {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy registry value for \(key) is not a string."
            )
        }
        return string
    }

    /// Sends one service request and validates common error fields.
    private func request(
        _ dictionary: [String: Any]
    ) async throws -> [String: Any] {
        try await PropertyListMessageFramer.send(
            dictionary,
            to: connection
        )
        let response = try await PropertyListMessageFramer.receive(
            from: connection
        )
        if let error = response.string("Error") {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy rejected the request: \(error)"
            )
        }
        return response
    }
}
