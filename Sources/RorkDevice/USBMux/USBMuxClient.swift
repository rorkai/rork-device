#if canImport(NIOPosix) && !os(WASI)
import Foundation

/// Device record returned by the local usbmux daemon.
///
/// This is the raw discovery form used by `USBMuxClient`. Higher-level callers
/// usually receive `Device` values from `DeviceClient.discoverDevices()` instead.
public struct USBMuxDevice: Equatable, Sendable {
    /// Numeric id assigned by usbmux for the current attachment.
    public let deviceID: UInt32

    /// Device serial number, normally the UDID.
    public let serialNumber: String

    /// Raw usbmux properties converted to strings where possible.
    public let properties: [String: String]

    /// Creates a usbmux device record from decoded daemon fields.
    ///
    /// - Parameters:
    ///   - deviceID: Numeric id assigned by usbmux for the current attachment.
    ///   - serialNumber: Device serial number, normally the UDID.
    ///   - properties: Raw usbmux properties converted to strings where possible.
    public init(deviceID: UInt32, serialNumber: String, properties: [String: String]) {
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.properties = properties
    }
}

/// Device attachment event emitted by usbmux.
///
/// The local usbmux daemon can keep a listen connection open and stream device
/// attach/detach events. This enum preserves the typed device record for
/// attach events while still carrying the numeric id for detach events, where
/// daemons commonly send less metadata.
public enum USBMuxDeviceEvent: Equatable, Sendable {
    /// A device became visible to usbmux.
    case attached(USBMuxDevice)

    /// A device disappeared from usbmux.
    case detached(deviceID: UInt32, serialNumber: String?)
}

/// Client for the usbmux plist protocol.
///
/// usbmux is the local broker that discovers attached iOS devices and forwards
/// host-side sockets to device service ports. `USBMuxClient` implements the
/// plist message variant used by modern Apple platforms and supports both the
/// standard Unix-domain socket and TCP endpoints for tests or forwarding.
///
/// A client can be reused for independent usbmux control requests. Each request
/// opens its own daemon connection, while `deviceEvents()` owns one long-lived
/// listen connection for the lifetime of the returned async sequence.
public final class USBMuxClient: Sendable {
    private let endpoint: USBMuxEndpoint
    private let requestTagGenerator = USBMuxRequestTagGenerator()

    /// Creates a usbmux client for a local or forwarded endpoint.
    ///
    /// The default endpoint is `/var/run/usbmuxd`, the standard Unix-domain
    /// socket on macOS and Linux hosts that run usbmux.
    public init(endpoint: USBMuxEndpoint = .default) {
        self.endpoint = endpoint
    }

    /// Creates a usbmux client that connects to a TCP endpoint.
    ///
    /// This is useful for integration tests, forwarded daemon sockets, and
    /// environments where another process exposes a usbmux-compatible service.
    public convenience init(host: String, port: UInt16) {
        self.init(endpoint: .tcp(host: host, port: port))
    }

    /// Lists devices currently reported by usbmux.
    ///
    /// - Returns: Raw usbmux device records.
    /// - Throws: Transport errors when the daemon is unavailable and protocol
    ///   errors when the response cannot be decoded.
    public func listDevices() async throws -> [USBMuxDevice] {
        let response = try await request([
            "MessageType": "ListDevices",
            "ClientVersionString": "rork-device",
            "ProgName": "rorkdevice",
            "kLibUSBMuxVersion": 3,
        ])
        let rawDevices = response["DeviceList"] as? [[String: Any]] ?? []
        return rawDevices.compactMap { item in
            parseDeviceRecord(item)
        }
    }

    /// Reads the host identifier maintained by the local usbmux daemon.
    ///
    /// Lockdown pairing records include this value as `SystemBUID`. It belongs
    /// to the host usbmux installation rather than to an individual device and
    /// must be read before creating new pairing material.
    ///
    /// - Returns: Nonempty host system BUID.
    /// - Throws: A transport or protocol error when usbmux cannot provide a
    ///   valid identifier.
    public func systemBUID() async throws -> String {
        let response = try await request([
            "MessageType": "ReadBUID",
            "ClientVersionString": "rork-device",
            "ProgName": "rorkdevice",
            "kLibUSBMuxVersion": 3,
        ])
        guard let value = response["BUID"] as? String else {
            throw RorkDeviceError.protocolViolation(
                "usbmux ReadBUID response was missing BUID."
            )
        }
        let systemBUID = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !systemBUID.isEmpty else {
            throw RorkDeviceError.protocolViolation(
                "usbmux ReadBUID response contained an empty BUID."
            )
        }
        return systemBUID
    }

    /// Reads the host pairing record stored by the local usbmux daemon.
    ///
    /// usbmux stores pairing records by device identifier and returns the
    /// original property-list bytes. Some daemon implementations omit `UDID`
    /// from that inner record because it is already the lookup key. This method
    /// backfills a missing identifier and rejects a stored identifier that does
    /// not exactly match the requested device.
    ///
    /// - Parameter deviceIdentifier: Device UDID used as the usbmux record key.
    /// - Returns: Validated Lockdown pairing material for the device.
    /// - Throws: A transport or protocol error when usbmux cannot return a
    ///   complete pairing record, or `RorkDeviceError.invalidPairingRecord`
    ///   when the stored property list is malformed.
    public func pairingRecord(
        for deviceIdentifier: String
    ) async throws -> PairingRecord {
        let response = try await request([
            "MessageType": "ReadPairRecord",
            "ClientVersionString": "rork-device",
            "ProgName": "rorkdevice",
            "kLibUSBMuxVersion": 3,
            "PairRecordID": deviceIdentifier,
        ])
        if let number = response["Number"] as? NSNumber,
            number.intValue != 0
        {
            throw RorkDeviceError.transport(
                "usbmux ReadPairRecord failed with code \(number.intValue)."
            )
        }
        guard let recordData = response["PairRecordData"] as? Data else {
            throw RorkDeviceError.protocolViolation(
                "usbmux ReadPairRecord response was missing PairRecordData."
            )
        }
        guard
            var dictionary = try PropertyListCodec.decode(recordData)
                as? [String: Any]
        else {
            throw RorkDeviceError.invalidPairingRecord(
                "Expected plist dictionary."
            )
        }
        switch dictionary["UDID"] {
        case let storedIdentifier as String:
            guard storedIdentifier == deviceIdentifier else {
                throw RorkDeviceError.invalidPairingRecord(
                    "Pairing record UDID does not match the requested device."
                )
            }

        case nil:
            dictionary["UDID"] = deviceIdentifier

        default:
            throw RorkDeviceError.invalidPairingRecord(
                "Pairing record UDID must be a string when present."
            )
        }
        return try PairingRecord.parse(
            PropertyListCodec.encode(dictionary, format: .binary)
        )
    }

    /// Saves a complete Lockdown pairing record through the usbmux daemon.
    ///
    /// usbmux owns the platform-specific storage location and permissions for
    /// host pairing material. Saving through the daemon keeps later Lockdown
    /// clients, Finder, and other host tools consistent with the newly trusted
    /// identity.
    ///
    /// Associating the record with the current attachment lets usbmux publish
    /// the accepted trust state without requiring a physical reconnect.
    ///
    /// - Parameters:
    ///   - pairingRecord: Pairing material whose `udid` becomes the usbmux
    ///     record identifier.
    ///   - deviceID: Current usbmux attachment identifier, when the device is
    ///     connected.
    /// - Throws: A serialization, transport, or usbmux rejection error.
    public func savePairingRecord(
        _ pairingRecord: PairingRecord,
        deviceID: UInt32? = nil
    ) async throws {
        var requestValues: [String: Any] = [
            "MessageType": "SavePairRecord",
            "ClientVersionString": "rork-device",
            "ProgName": "rorkdevice",
            "kLibUSBMuxVersion": 3,
            "PairRecordID": pairingRecord.udid,
            "PairRecordData": try pairingRecord.propertyListData(),
        ]
        if let deviceID {
            requestValues["DeviceID"] = deviceID
        }
        let response = try await request(requestValues)
        try validateUSBMuxResult(
            response,
            operation: "SavePairRecord"
        )
    }

    /// Removes the host pairing record stored by the local usbmux daemon.
    ///
    /// This operation deletes only the host's persisted credentials. It does
    /// not revoke the corresponding trusted identity from the device. Use
    /// `DeviceClient.unpair(from:)` when both sides of the pairing must be
    /// removed as one ordered workflow.
    ///
    /// - Parameter deviceIdentifier: Device UDID used as the usbmux record key.
    /// - Throws: A transport or usbmux rejection error when the record cannot
    ///   be removed.
    public func removePairingRecord(
        for deviceIdentifier: String
    ) async throws {
        let response = try await request([
            "MessageType": "DeletePairRecord",
            "ClientVersionString": "rork-device",
            "ProgName": "rorkdevice",
            "kLibUSBMuxVersion": 3,
            "PairRecordID": deviceIdentifier,
        ])
        try validateUSBMuxResult(
            response,
            operation: "DeletePairRecord"
        )
    }

    /// Opens a long-lived stream of usbmux device events.
    ///
    /// The stream sends a `Listen` request to the configured usbmux endpoint and
    /// yields attach/detach events until the daemon closes the connection, the
    /// consumer cancels iteration, or a protocol error occurs. Cancelling the
    /// returned sequence closes the underlying listen socket so a suspended read
    /// does not keep the daemon connection alive.
    ///
    /// - Returns: Async sequence of device visibility events.
    public func deviceEvents() -> AsyncThrowingStream<USBMuxDeviceEvent, Error> {
        AsyncThrowingStream { continuation in
            let listenState = USBMuxListenConnectionState()
            let task = Task {
                let connection: DeviceConnection
                do {
                    connection = try await openConnection()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                guard listenState.install(connection) else {
                    connection.close()
                    continuation.finish()
                    return
                }

                do {
                    let response = try await request(
                        [
                            "MessageType": "Listen",
                            "ClientVersionString": "rork-device",
                            "ProgName": "rorkdevice",
                            "kLibUSBMuxVersion": 3,
                        ], connection: connection)
                    try validateUSBMuxResult(response, operation: "Listen")

                    while !Task.isCancelled {
                        let message = try await readResponseDictionary(from: connection)
                        if let event = parseDeviceEvent(message) {
                            continuation.yield(event)
                        }
                    }
                    connection.close()
                    listenState.clear(connection)
                    continuation.finish()
                } catch {
                    connection.close()
                    listenState.clear(connection)
                    if Task.isCancelled || isUSBMuxListenClosed(error) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                listenState.cancel()
                task.cancel()
            }
        }
    }

    /// Opens a forwarded connection to a device service port.
    ///
    /// The returned connection speaks directly to the requested service on the
    /// device. The usbmux control response has already succeeded by the time
    /// this method returns.
    ///
    /// - Parameters:
    ///   - device: Device record returned by `listDevices()`.
    ///   - port: Device-side service port, in host byte order.
    public func connect(to device: USBMuxDevice, port: UInt16) async throws -> DeviceConnection {
        try await connect(toDeviceID: device.deviceID, port: port)
    }

    /// Opens a forwarded connection to a device service port by numeric id.
    func connect(toDeviceID deviceID: UInt32, port: UInt16) async throws -> DeviceConnection {
        let connection = try await openConnection()
        do {
            let response = try await request(
                [
                    "MessageType": "Connect",
                    "ClientVersionString": "rork-device",
                    "ProgName": "rorkdevice",
                    "DeviceID": deviceID,
                    "PortNumber": UInt32(port.bigEndian),
                ], connection: connection)

            try validateUSBMuxResult(response, operation: "Connect")
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Sends a one-shot usbmux control request.
    private func request(_ dictionary: [String: Any]) async throws -> [String: Any] {
        let connection = try await openConnection()
        defer { connection.close() }
        return try await request(dictionary, connection: connection)
    }

    /// Opens a connection to the configured usbmux endpoint.
    private func openConnection() async throws -> DeviceConnection {
        switch endpoint {
        case .unixSocket(let path):
            return try await UnixDomainSocketConnection.connect(toSocketAt: path)
        case .tcp(let host, let port):
            return try await TCPDeviceConnection.connect(to: host, port: port)
        }
    }

    /// Sends a usbmux request over an existing connection.
    private func request(_ dictionary: [String: Any], connection: DeviceConnection) async throws
        -> [String: Any]
    {
        let tag = await requestTagGenerator.next()
        let payload = try PropertyListCodec.encode(dictionary, format: .xml)
        try await connection.send(try USBMuxPacket(tag: tag, payload: payload).encoded())
        return try await readResponseDictionary(from: connection)
    }

    /// Reads one usbmux plist response dictionary.
    private func readResponseDictionary(from connection: DeviceConnection) async throws -> [String:
        Any]
    {
        let header = try await connection.receive(exactly: USBMuxPacket.headerLength)
        let length = try Int(header.littleEndianInteger(at: 0, as: UInt32.self))
        guard length >= USBMuxPacket.headerLength else {
            throw RorkDeviceError.protocolViolation("Invalid usbmux response length \(length).")
        }

        let payloadLength = length - USBMuxPacket.headerLength
        let responsePayload = try await connection.receive(exactly: payloadLength)
        let responsePacket = try USBMuxPacket.decode(header: header, payload: responsePayload)
        guard responsePacket.messageType == USBMuxPacket.plistMessageType else {
            throw RorkDeviceError.protocolViolation(
                "Unsupported usbmux response message type \(responsePacket.messageType).")
        }
        guard let response = try PropertyListCodec.decode(responsePacket.payload) as? [String: Any]
        else {
            throw RorkDeviceError.protocolViolation("usbmux response was not a dictionary.")
        }
        return response
    }
}

/// Allocates nonzero usbmux request tags across concurrent control operations.
///
/// Every control request owns a separate daemon connection, so tag allocation
/// is the only mutable state shared by `USBMuxClient` operations. Actor
/// isolation keeps that state race-free without placing the entire client
/// behind one executor.
private actor USBMuxRequestTagGenerator {
    /// Tag reserved for the next request.
    private var nextTag: UInt32 = 1

    /// Returns one tag and advances the sequence, skipping zero after overflow.
    func next() -> UInt32 {
        let tag = nextTag
        nextTag &+= 1
        if nextTag == 0 {
            nextTag = 1
        }
        return tag
    }
}

/// Tracks the live usbmux listen connection so cancellation can close it.
///
/// `AsyncThrowingStream` cancellation only cancels the task consuming the stream;
/// it does not automatically unblock a transport read. This helper lets the
/// termination handler close the socket even while the task is suspended in
/// `receive(exactly:)`.
///
/// The producer task and termination handler may access this state concurrently.
/// The lock protects connection ownership and cancellation state, and socket
/// closure is the only operation performed outside that critical section.
private final class USBMuxListenConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: DeviceConnection?
    private var cancelled = false

    /// Stores the listen connection unless the stream was already cancelled.
    func install(_ connection: DeviceConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancelled else {
            return false
        }
        self.connection = connection
        return true
    }

    /// Clears the stored connection after normal task completion.
    func clear(_ connection: DeviceConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
        }
        lock.unlock()
    }

    /// Marks the stream cancelled and closes any installed listen connection.
    func cancel() {
        let connectionToClose: DeviceConnection?
        lock.lock()
        cancelled = true
        connectionToClose = connection
        connection = nil
        lock.unlock()

        connectionToClose?.close()
    }
}

/// Endpoint used to reach usbmux.
public enum USBMuxEndpoint: Equatable, Sendable {
    /// Unix-domain socket path for a local daemon.
    case unixSocket(path: String)

    /// TCP endpoint for a forwarded or embedded usbmux-compatible peer.
    case tcp(host: String, port: UInt16)

    /// Standard platform endpoint used by Apple-host tooling.
    public static let `default` = USBMuxEndpoint.unixSocket(path: "/var/run/usbmuxd")
}

/// `DeviceTransport` implementation backed by usbmux forwarding.
///
/// `DeviceSession` uses this transport to open Lockdown and later service
/// connections for the same physical device.
public struct USBMuxDeviceTransport: DeviceTransport {
    private let deviceID: UInt32
    private let usbmuxClient: USBMuxClient

    /// Creates a transport for a usbmux device id.
    ///
    /// The device id should come from a recent `USBMuxClient.listDevices()` call.
    public init(deviceID: UInt32, usbmuxClient: USBMuxClient = USBMuxClient()) {
        self.deviceID = deviceID
        self.usbmuxClient = usbmuxClient
    }

    /// Opens a usbmux-forwarded connection to a device port.
    public func connect(to port: UInt16) async throws -> DeviceConnection {
        try await usbmuxClient.connect(toDeviceID: deviceID, port: port)
    }
}

/// Converts scalar plist values to printable strings.
private func stringify(_ dictionary: [String: Any]) -> [String: String] {
    dictionary.compactMapValues { value in
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

/// Parses a usbmux device record from a plist dictionary.
private func parseDeviceRecord(_ item: [String: Any]) -> USBMuxDevice? {
    guard
        let deviceID = (item["DeviceID"] as? NSNumber)?.uint32Value ?? item["DeviceID"] as? UInt32,
        let properties = item["Properties"] as? [String: Any],
        let serial = properties["SerialNumber"] as? String
    else {
        return nil
    }
    return USBMuxDevice(deviceID: deviceID, serialNumber: serial, properties: stringify(properties))
}

/// Parses a streamed usbmux attach or detach event.
private func parseDeviceEvent(_ message: [String: Any]) -> USBMuxDeviceEvent? {
    switch message["MessageType"] as? String {
    case "Attached":
        guard let device = parseDeviceRecord(message) else {
            return nil
        }
        return .attached(device)
    case "Detached":
        guard
            let deviceID = (message["DeviceID"] as? NSNumber)?.uint32Value ?? message["DeviceID"]
                as? UInt32
        else {
            return nil
        }
        return .detached(deviceID: deviceID, serialNumber: message["SerialNumber"] as? String)
    default:
        return nil
    }
}

/// Validates the numeric result field used by usbmux control responses.
private func validateUSBMuxResult(_ response: [String: Any], operation: String) throws {
    guard let number = response["Number"] as? NSNumber else {
        throw RorkDeviceError.protocolViolation("usbmux \(operation) response was missing Number.")
    }
    if number.intValue != 0 {
        throw RorkDeviceError.transport("usbmux \(operation) failed with code \(number.intValue).")
    }
}

/// Returns true when a usbmux listen stream ended because the peer closed it.
private func isUSBMuxListenClosed(_ error: Error) -> Bool {
    guard case RorkDeviceError.transport("Connection closed.") = error else {
        return false
    }
    return true
}
#endif
