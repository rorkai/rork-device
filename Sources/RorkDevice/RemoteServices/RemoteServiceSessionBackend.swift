import Foundation

/// Opens a byte stream to one port advertised by Remote Service Discovery.
typealias RemoteServiceConnectionFactory = (_ host: String, _ port: UInt16) async throws -> DeviceConnection

/// Resolves and opens services from a live Remote Service Discovery session.
final class RemoteServiceSessionBackend: DeviceSessionBackend {
    /// Device-side address reachable through the active packet tunnel.
    private let host: String

    /// Service map advertised by the retained discovery session.
    private let directory: RemoteServiceDirectory

    /// Client label included in each RSD check-in request.
    private let label: String

    /// Strong reference that keeps the advertisement's service ports valid.
    private let retainedDiscoverySession: RemoteServiceDiscoverySession?

    /// Injectable connection factory used for service streams and tests.
    private let openConnection: RemoteServiceConnectionFactory

    /// Creates a backend bound to one live discovery advertisement.
    init(
        host: String,
        directory: RemoteServiceDirectory,
        label: String,
        retaining discoverySession: RemoteServiceDiscoverySession? = nil,
        openConnection: @escaping RemoteServiceConnectionFactory = { host, port in
            try await TCPDeviceConnection.connect(to: host, port: port)
        }
    ) {
        self.host = host
        self.directory = directory
        self.label = label
        retainedDiscoverySession = discoverySession
        self.openConnection = openConnection
    }

    /// Returns the device identifier supplied by the discovery handshake.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        var values: [String: Any] = [:]
        if let deviceIdentifier = directory.deviceIdentifier {
            values["UniqueDeviceID"] = deviceIdentifier
        }
        return DeviceInfo(values: values)
    }

    /// Connects to an advertised service and completes its two-message RSD check-in.
    func startService(named serviceName: String, escrowBag _: Data?) async throws -> DeviceConnection {
        let advertisedName = directory.services[serviceName] == nil
            ? "\(serviceName).shim.remote"
            : serviceName
        guard let port = directory.port(for: serviceName) else {
            throw RorkDeviceError.protocolViolation(
                "Remote service directory does not advertise \(advertisedName)."
            )
        }

        let connection: DeviceConnection
        do {
            connection = try await openConnection(host, port)
        } catch {
            throw RorkDeviceError.transport(
                "Failed to connect \(advertisedName) on \(host):\(port): \(describeDeviceSessionError(error))"
            )
        }

        do {
            try await performCheckIn(
                over: connection,
                serviceName: advertisedName,
                endpoint: remoteServiceEndpointDescription(host: host, port: port)
            )
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Exchanges RSDCheckin and StartService before exposing the service protocol.
    private func performCheckIn(
        over connection: DeviceConnection,
        serviceName: String,
        endpoint: String
    ) async throws {
        do {
            try await PropertyListMessageFramer.send([
                "Label": label,
                "ProtocolVersion": "2",
                "Request": "RSDCheckin",
            ], to: connection)
        } catch {
            throw RorkDeviceError.transport(
                "Remote service \(serviceName) on \(endpoint) failed while sending RSDCheckin: \(describeDeviceSessionError(error))"
            )
        }

        do {
            try await requireResponse(for: "RSDCheckin", from: connection)
        } catch {
            throw makeCheckInError(
                from: error,
                serviceName: serviceName,
                endpoint: endpoint,
                expectedRequest: "RSDCheckin"
            )
        }

        do {
            try await requireResponse(for: "StartService", from: connection)
        } catch {
            throw makeCheckInError(
                from: error,
                serviceName: serviceName,
                endpoint: endpoint,
                expectedRequest: "StartService"
            )
        }
    }

    /// Validates the next check-in response against its expected request name.
    private func requireResponse(
        for expectedRequest: String,
        from connection: DeviceConnection
    ) async throws {
        let response = try await PropertyListMessageFramer.receive(from: connection)
        let actualRequest = response.string("Request")
        guard actualRequest == expectedRequest else {
            throw RorkDeviceError.protocolViolation(
                "RSD check-in expected \(expectedRequest), received \(actualRequest ?? "no Request value")."
            )
        }

        if let serviceError = response["Error"] {
            throw RorkDeviceError.protocolViolation(
                "RSD check-in \(expectedRequest) failed: \(String(describing: serviceError))."
            )
        }
    }

    /// Adds service and endpoint context while preserving protocol failures.
    private func makeCheckInError(
        from error: Error,
        serviceName: String,
        endpoint: String,
        expectedRequest: String
    ) -> RorkDeviceError {
        if case let .protocolViolation(message) = error as? RorkDeviceError {
            return .protocolViolation(
                "Remote service \(serviceName) on \(endpoint) returned an invalid \(expectedRequest) response: \(message)"
            )
        }

        return .transport(
            "Remote service \(serviceName) on \(endpoint) closed while waiting for \(expectedRequest): \(describeDeviceSessionError(error))"
        )
    }
}

/// Formats an IPv4, hostname, or bracketed IPv6 endpoint for diagnostics.
private func remoteServiceEndpointDescription(host: String, port: UInt16) -> String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
}
