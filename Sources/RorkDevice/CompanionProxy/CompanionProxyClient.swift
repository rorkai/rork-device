import Foundation

/// Client for the `com.apple.companion_proxy` service.
///
/// The service exposes devices paired through the connected iPhone and values
/// from each paired device's registry. Create the client with a connection from
/// `DeviceSession.startService(named:)` using `serviceName`.
///
/// The unchecked conformance is safe because an internal gate serializes every
/// complete request and response on the immutable connection reference. Callers
/// must not access or close that connection while client requests are pending.
public final class CompanionProxyClient: @unchecked Sendable {
    /// Lockdown identifier used to start the companion proxy service.
    public static let serviceName = "com.apple.companion_proxy"

    /// Byte stream carrying framed companion proxy property lists.
    private let connection: DeviceConnection

    /// Gate that prevents concurrent callers from consuming another request's
    /// response.
    private let requestGate = CompanionProxyRequestGate()

    /// Number of requests waiting behind the active exchange.
    var queuedRequestCount: Int {
        get async {
            await requestGate.waiterCount
        }
    }

    /// Creates a client over an existing companion proxy connection.
    ///
    /// The caller retains ownership of `connection`. It must remain untouched
    /// until every client request finishes and must then be closed by the caller.
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
        if response.string("Error") == "NoPairedWatches" {
            return []
        }
        try checkServiceError(response)
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

    /// Reads a typed registry value from one paired companion device.
    ///
    /// The key carries the expected result type while preserving an open set of
    /// wire names for newer or vendor-defined values.
    ///
    /// - Parameters:
    ///   - key: Registry key to read.
    ///   - deviceIdentifier: Identifier returned by
    ///     `pairedDeviceIdentifiers()`.
    /// - Returns: The property-list value, or `nil` when the key is absent.
    /// - Throws: An input error for an empty key or identifier, plus transport
    ///   and protocol errors. A protocol violation is thrown when a present
    ///   value does not match the key's declared type.
    public func value<Value>(
        for key: CompanionRegistryKey<Value>,
        on deviceIdentifier: String
    ) async throws -> Value? {
        guard !deviceIdentifier.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Companion device identifier must not be empty."
            )
        }
        guard !key.rawValue.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Companion device registry key must not be empty."
            )
        }

        let response = try await request([
            "Command": "GetValueFromRegistry",
            "GetValueGizmoUDIDKey": deviceIdentifier,
            "GetValueKeyKey": key.rawValue,
        ])
        if response.string("Error") == "UnsupportedWatchKey" {
            return nil
        }
        try checkServiceError(response)
        guard let values =
            response["RetrievedValueDictionary"] as? [String: Any] else {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy value response is missing RetrievedValueDictionary."
            )
        }
        guard let rawValue = values[key.rawValue] else {
            return nil
        }
        guard let value = rawValue as? Value else {
            let expectedType = String(describing: Value.self)
            let message =
                "Companion proxy registry value for \(key.rawValue) " +
                "does not match \(expectedType)."
            throw RorkDeviceError.protocolViolation(message)
        }
        return value
    }

    /// Performs one serialized service request and response exchange.
    private func request(
        _ dictionary: [String: Any]
    ) async throws -> [String: Any] {
        try await requestGate.acquire()
        do {
            try await PropertyListMessageFramer.send(
                dictionary,
                to: connection
            )
            let response = try await PropertyListMessageFramer.receive(
                from: connection
            )
            await requestGate.release(streamIsAligned: true)
            return response
        } catch {
            await requestGate.release(streamIsAligned: false)
            throw error
        }
    }

    /// Rejects service errors that the calling operation did not normalize.
    private func checkServiceError(
        _ response: [String: Any]
    ) throws {
        guard let rawError = response["Error"] else {
            return
        }
        guard let error = rawError as? String else {
            throw RorkDeviceError.protocolViolation(
                "Companion proxy response contains a non-string Error field."
            )
        }
        throw RorkDeviceError.protocolViolation(
            "Companion proxy rejected the request: \(error)"
        )
    }
}

/// Serializes complete exchanges without blocking a cooperative executor.
private actor CompanionProxyRequestGate {
    /// Whether one request currently owns the service stream.
    private var isHeld = false

    /// Callers waiting to acquire the stream in submission order.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether an interrupted exchange may have left a partial frame.
    private var isPoisoned = false

    /// Number of callers currently waiting for the stream.
    var waiterCount: Int {
        waiters.count
    }

    /// Waits until the caller owns the service stream.
    func acquire() async throws {
        if isPoisoned {
            throw failedExchangeError()
        }
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation {
            waiters.append($0)
        }
        if isPoisoned {
            release(streamIsAligned: false)
            throw failedExchangeError()
        }
    }

    /// Releases the stream and records whether another request may safely use it.
    func release(streamIsAligned: Bool) {
        precondition(isHeld, "Companion proxy request gate was not acquired.")
        if !streamIsAligned {
            isPoisoned = true
        }
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }

    /// Creates the stable error returned after an interrupted exchange.
    private func failedExchangeError() -> RorkDeviceError {
        .protocolViolation(
            "Companion proxy stream cannot continue after a failed exchange."
        )
    }
}
