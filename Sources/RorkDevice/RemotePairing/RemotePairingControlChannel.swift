import Foundation

/// Transport-neutral outer channel used by Apple's remote-pairing protocol.
///
/// The pairing state machine is identical on the direct `RPPairing` socket and
/// the untrusted RemoteXPC service. Only the outer envelope encoding differs:
/// direct sockets carry length-prefixed JSON, while RemoteXPC preserves binary
/// values in its native object format.
protocol RemotePairingControlChannel: AnyObject {
    /// Sends one unencrypted protocol payload.
    func sendPlain(_ payload: [String: Any]) async throws

    /// Receives one unencrypted protocol payload.
    func receivePlain() async throws -> [String: Any]

    /// Sends one encrypted-stream payload.
    func sendEncrypted(_ ciphertext: Data) async throws

    /// Receives one encrypted-stream payload.
    func receiveEncrypted() async throws -> Data
}

/// Remote-pairing channel carried directly over the `RPPairing` TCP protocol.
final class RemotePairingFramedControlChannel: RemotePairingControlChannel {
    /// Connected stream using the protocol's magic-prefixed JSON framing.
    private let connection: DeviceConnection

    /// Sequence number attached to the next host message.
    private var sequenceNumber = 0

    /// Creates a direct channel over an established byte stream.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Sends one JSON-compatible plain payload.
    func sendPlain(_ payload: [String: Any]) async throws {
        try await send(message: [
            "plain": [
                "_0": try jsonCompatibleValue(payload),
            ],
        ])
    }

    /// Receives and extracts one direct-channel plain payload.
    func receivePlain() async throws -> [String: Any] {
        let message = try await receiveMessage()
        guard let payload = remotePairingNestedDictionary(
            message,
            keys: ["plain", "_0"]
        ) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing response is missing a plain message payload."
            )
        }
        return payload
    }

    /// Sends ciphertext as the base64 value required by JSON framing.
    func sendEncrypted(_ ciphertext: Data) async throws {
        try await send(message: [
            "streamEncrypted": [
                "_0": ciphertext.base64EncodedString(),
            ],
        ])
    }

    /// Receives and decodes one base64 encrypted-stream value.
    func receiveEncrypted() async throws -> Data {
        let message = try await receiveMessage()
        guard let base64 = remotePairingNestedValue(
            message,
            keys: ["streamEncrypted", "_0"]
        ) as? String,
              let ciphertext = Data(base64Encoded: base64) else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing encrypted response is missing data."
            )
        }
        return ciphertext
    }

    /// Wraps one message with host metadata and sends its direct frame.
    private func send(message: [String: Any]) async throws {
        let frame = try RemotePairingFrameCodec.encode([
            "message": message,
            "originatedBy": "host",
            "sequenceNumber": sequenceNumber,
        ])
        try await connection.send(frame)
        sequenceNumber += 1
    }

    /// Receives one direct frame and extracts its message envelope.
    private func receiveMessage() async throws -> [String: Any] {
        let frame = try await RemotePairingFrameCodec.receive(
            from: connection
        )
        guard let message = frame["message"] as? [String: Any] else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing response is missing its message envelope."
            )
        }
        return message
    }

    /// Converts binary values recursively into JSON's base64 representation.
    private func jsonCompatibleValue(_ value: Any) throws -> Any {
        switch value {
        case let data as Data:
            return data.base64EncodedString()

        case let dictionary as [String: Any]:
            var converted: [String: Any] = [:]
            for (key, value) in dictionary {
                converted[key] = try jsonCompatibleValue(value)
            }
            return converted

        case let array as [Any]:
            return try array.map(jsonCompatibleValue)

        default:
            return value
        }
    }
}

/// Remote-pairing channel carried by the untrusted RemoteXPC tunnel service.
final class RemotePairingRemoteXPCChannel: RemotePairingControlChannel {
    /// Mangled Swift type name required by the device's control service.
    private static let envelopeTypeName =
        "RemotePairing.ControlChannelMessageEnvelope"

    /// Maximum setup or unrelated messages skipped before rejecting the stream.
    private static let maximumMessagesWithoutEnvelope = 32

    /// Live RemoteXPC transport to the untrusted tunnel service.
    private let connection: RemoteXPCConnection

    /// Sequence number attached to the next host message.
    private var sequenceNumber: UInt64 = 1

    /// Creates a channel over an initialized RemoteXPC connection.
    private init(connection: RemoteXPCConnection) {
        self.connection = connection
    }

    /// Opens RemoteXPC and prepares a remote-pairing control channel.
    static func open(
        over connection: DeviceConnection
    ) async throws -> RemotePairingRemoteXPCChannel {
        RemotePairingRemoteXPCChannel(
            connection: try await RemoteXPCConnection.open(
                over: connection
            )
        )
    }

    /// Sends one plain payload without converting binary values to base64.
    func sendPlain(_ payload: [String: Any]) async throws {
        try await send(message: .dictionary([
            "plain": .dictionary([
                "_0": try remoteXPCValue(payload),
            ]),
        ]))
    }

    /// Receives a plain RemoteXPC payload and converts it to Foundation values.
    func receivePlain() async throws -> [String: Any] {
        let message = try await receiveMessage()
        guard case let .dictionary(plain)? = message["plain"],
              case let .dictionary(payload)? = plain["_0"] else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing response is missing a plain message payload."
            )
        }
        return foundationDictionary(payload)
    }

    /// Sends ciphertext as native RemoteXPC data.
    func sendEncrypted(_ ciphertext: Data) async throws {
        try await send(message: .dictionary([
            "streamEncrypted": .dictionary([
                "_0": .data(ciphertext),
            ]),
        ]))
    }

    /// Receives one native RemoteXPC encrypted-stream value.
    func receiveEncrypted() async throws -> Data {
        let message = try await receiveMessage()
        guard case let .dictionary(encrypted)? = message["streamEncrypted"],
              case let .data(ciphertext)? = encrypted["_0"] else {
            throw RorkDeviceError.protocolViolation(
                "Remote pairing encrypted response is missing data."
            )
        }
        return ciphertext
    }

    /// Closes the owned RemoteXPC service connection.
    func close() {
        connection.close()
    }

    /// Wraps and sends one control-channel message.
    private func send(message: RemoteXPCValue) async throws {
        try await connection.send(.dictionary([
            "mangledTypeName": .string(Self.envelopeTypeName),
            "value": .dictionary([
                "message": message,
                "originatedBy": .string("host"),
                "sequenceNumber": .uint64(sequenceNumber),
            ]),
        ]))
        sequenceNumber += 1
    }

    /// Waits for the next control-channel envelope, skipping setup messages.
    private func receiveMessage() async throws -> [String: RemoteXPCValue] {
        for _ in 0..<Self.maximumMessagesWithoutEnvelope {
            let message = try await connection.receive()
            guard case let .dictionary(root)? = message.value,
                  case let .dictionary(value)? = root["value"],
                  case let .dictionary(payload)? = value["message"] else {
                continue
            }
            return payload
        }
        throw RorkDeviceError.protocolViolation(
            "Remote pairing received too many messages without a control-channel envelope."
        )
    }
}

/// Converts one Foundation value into the RemoteXPC object model.
private func remoteXPCValue(_ value: Any) throws -> RemoteXPCValue {
    switch value {
    case let value as RemoteXPCValue:
        return value
    case let value as Data:
        return .data(value)
    case let value as String:
        return .string(value)
    case let value as Bool:
        return .bool(value)
    case let value as Int:
        return .int64(Int64(value))
    case let value as Int64:
        return .int64(value)
    case let value as UInt:
        return .uint64(UInt64(value))
    case let value as UInt64:
        return .uint64(value)
    case let value as Double:
        return .double(value)
    case let values as [Any]:
        return .array(try values.map(remoteXPCValue))
    case let values as [String: Any]:
        var converted: [String: RemoteXPCValue] = [:]
        for (key, value) in values {
            converted[key] = try remoteXPCValue(value)
        }
        return .dictionary(converted)
    default:
        throw RorkDeviceError.invalidInput(
            "Remote pairing cannot encode \(String(describing: type(of: value))) in RemoteXPC."
        )
    }
}

/// Converts a RemoteXPC dictionary into values consumed by the pairing state machine.
private func foundationDictionary(
    _ values: [String: RemoteXPCValue]
) -> [String: Any] {
    values.mapValues(foundationValue)
}

/// Converts one RemoteXPC value into its closest Foundation representation.
private func foundationValue(_ value: RemoteXPCValue) -> Any {
    switch value {
    case .null:
        return NSNull()
    case let .bool(value):
        return value
    case let .int64(value):
        return NSNumber(value: value)
    case let .uint64(value):
        return NSNumber(value: value)
    case let .double(value):
        return NSNumber(value: value)
    case let .date(value):
        return NSNumber(value: value)
    case let .data(value):
        return value
    case let .string(value):
        return value
    case let .uuid(value):
        return value
    case let .array(values):
        return values.map(foundationValue)
    case let .dictionary(values):
        return foundationDictionary(values)
    }
}

/// Reads a nested remote-pairing dictionary at the supplied key path.
func remotePairingNestedDictionary(
    _ dictionary: [String: Any],
    keys: [String]
) -> [String: Any]? {
    remotePairingNestedValue(dictionary, keys: keys) as? [String: Any]
}

/// Reads an arbitrary nested remote-pairing value at the supplied key path.
func remotePairingNestedValue(
    _ dictionary: [String: Any],
    keys: [String]
) -> Any? {
    var value: Any = dictionary
    for key in keys {
        guard let current = value as? [String: Any],
              let next = current[key] else {
            return nil
        }
        value = next
    }
    return value
}
