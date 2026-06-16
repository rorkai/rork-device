import Foundation

/// Owns a live discovery connection and the service directory it advertised.
final class RemoteServiceDiscoverySession {
    /// Service map whose ports remain valid while this session is retained.
    let directory: RemoteServiceDirectory

    /// Underlying RemoteXPC connection kept open for port validity.
    private let connection: RemoteXPCConnection

    /// Protects idempotent closure from explicit calls and `deinit`.
    private let stateLock = NSLock()

    /// Records whether ownership of the connection has already been released.
    private var isClosed = false

    /// Creates a session after the discovery handshake has completed.
    private init(
        directory: RemoteServiceDirectory,
        connection: RemoteXPCConnection
    ) {
        self.directory = directory
        self.connection = connection
    }

    /// Completes discovery over an established connection and takes ownership of it.
    static func open(over connection: DeviceConnection) async throws -> RemoteServiceDiscoverySession {
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        do {
            let directory = try await receiveServiceDirectory(
                from: remoteXPC
            )
            return RemoteServiceDiscoverySession(
                directory: directory,
                connection: remoteXPC
            )
        } catch {
            remoteXPC.close()
            throw error
        }
    }

    /// Closes the owned connection when the session leaves memory.
    deinit {
        close()
    }

    /// Closes the discovery connection exactly once.
    func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()
        connection.close()
    }

    /// Waits for the RemoteXPC handshake carrying device properties and services.
    private static func receiveServiceDirectory(
        from connection: RemoteXPCConnection
    ) async throws -> RemoteServiceDirectory {
        while true {
            let message = try await connection.receive()
            guard let root = message.value?.dictionaryValue else {
                continue
            }
            guard root["MessageType"]?.stringValue == "Handshake" else {
                continue
            }
            return try parseDirectory(from: root)
        }
    }

    /// Validates the discovery handshake and extracts its device-bound service map.
    private static func parseDirectory(
        from handshake: [String: RemoteXPCValue]
    ) throws -> RemoteServiceDirectory {
        guard let properties = handshake["Properties"]?.dictionaryValue,
              let deviceIdentifier = properties["UniqueDeviceID"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceIdentifier.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake does not contain a device identifier."
            )
        }
        guard let advertisedServices = handshake["Services"]?.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake does not contain a service directory."
            )
        }

        var services: [String: UInt16] = [:]
        for (name, value) in advertisedServices {
            guard let attributes = value.dictionaryValue,
                  let rawPort = attributes["Port"]?.integerValue else {
                continue
            }
            guard let port = UInt16(exactly: rawPort), port > 0 else {
                throw RorkDeviceError.protocolViolation(
                    "Remote service \(name) has invalid port \(rawPort)."
                )
            }
            services[name] = port
        }

        guard !services.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "Remote Service Discovery handshake contains no service ports."
            )
        }
        return RemoteServiceDirectory(
            deviceIdentifier: deviceIdentifier,
            services: services
        )
    }
}
