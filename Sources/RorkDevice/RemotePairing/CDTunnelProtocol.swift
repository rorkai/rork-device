import Foundation

/// Network configuration negotiated for a CoreDevice packet tunnel.
///
/// The host and device addresses define the private IPv6 link carried by
/// `CoreDeviceTunnel` or `RemotePairingTunnel`. Applications can apply these
/// values to a packet interface or use `CoreDeviceUserspaceNetwork` to expose
/// device services through `DeviceTransport`.
public struct CoreDeviceTunnelConfiguration: Equatable, Sendable {
    /// IPv6 address assigned to the host side of the private tunnel link.
    ///
    /// A packet-tunnel integration should configure this address on its local
    /// interface and use it as the source address for traffic sent to
    /// `deviceAddress`.
    public let hostAddress: String

    /// IPv6 address assigned to the device side of the private tunnel link.
    ///
    /// Device services advertised through Remote Service Discovery are reachable
    /// at this address while the associated tunnel remains open.
    public let deviceAddress: String

    /// IPv6 netmask reported by the device for the private tunnel link.
    ///
    /// The value is returned in textual IPv6 form. Network-extension clients
    /// can convert it to a prefix length when configuring their local route.
    public let networkMask: String

    /// Maximum complete IPv6 packet size negotiated for the tunnel.
    ///
    /// Callers should apply this value to their packet interface and avoid
    /// forwarding larger packets because the CoreDevice packet-tunnel
    /// implementations forward complete packets and do not fragment them.
    public let maximumTransmissionUnit: UInt16

    /// Port of the device's Remote Service Discovery endpoint.
    ///
    /// The endpoint is available at `deviceAddress` only through the active
    /// packet tunnel. Pass it to the `discoveryPort` parameter of
    /// `DeviceClient.connect(toRemoteServicesUsing:discoveryPort:label:)` when
    /// using `CoreDeviceUserspaceNetwork`, or connect to `deviceAddress`
    /// directly after configuring the tunnel on the host network stack.
    public let serviceDiscoveryPort: UInt16

    /// Creates a negotiated tunnel configuration.
    init(
        hostAddress: String,
        deviceAddress: String,
        networkMask: String,
        maximumTransmissionUnit: UInt16,
        serviceDiscoveryPort: UInt16
    ) {
        self.hostAddress = hostAddress
        self.deviceAddress = deviceAddress
        self.networkMask = networkMask
        self.maximumTransmissionUnit = maximumTransmissionUnit
        self.serviceDiscoveryPort = serviceDiscoveryPort
    }
}

/// Implements the framing and negotiation performed on the TLS tunnel stream.
enum CDTunnelProtocol {
    /// Fixed prefix identifying the CDTunnel byte stream.
    private static let magic = Data("CDTunnel".utf8)

    /// Negotiates IPv6 addresses, MTU, and the live service-discovery endpoint.
    static func negotiateConfiguration(
        over connection: DeviceConnection,
        requestedMaximumTransmissionUnit: UInt16
    ) async throws -> CoreDeviceTunnelConfiguration {
        let request = try JSONSerialization.data(withJSONObject: [
            "type": "clientHandshakeRequest",
            "mtu": Int(requestedMaximumTransmissionUnit),
        ])
        guard request.count <= Int(UInt16.max) else {
            throw RorkDeviceError.invalidInput("CDTunnel handshake request exceeds UInt16 length.")
        }

        var frame = Data()
        frame.append(magic)
        frame.appendBigEndian(UInt16(request.count))
        frame.append(request)
        try await connection.send(frame)

        let responseMagic = try await connection.receive(exactly: magic.count)
        guard responseMagic == magic else {
            throw RorkDeviceError.protocolViolation("CDTunnel handshake has an invalid magic prefix.")
        }
        let lengthData = try await connection.receive(exactly: 2)
        let length = try Int(lengthData.bigEndianInteger(at: 0, as: UInt16.self))
        guard length > 0 else {
            throw RorkDeviceError.protocolViolation("CDTunnel handshake response is empty.")
        }
        let responseData = try await connection.receive(exactly: length)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: responseData)
        } catch {
            throw RorkDeviceError.protocolViolation("CDTunnel handshake response is not valid JSON.")
        }
        guard let response = object as? [String: Any],
              let clientParameters = response["clientParameters"] as? [String: Any],
              let hostAddress = nonEmptyString(clientParameters["address"]),
              let deviceAddress = nonEmptyString(response["serverAddress"]),
              let networkMask = nonEmptyString(clientParameters["netmask"]),
              let mtu = RemotePairingJSONValue.positiveUInt16(
                  from: clientParameters["mtu"]
              ),
              let rsdPort = RemotePairingJSONValue.positiveUInt16(
                  from: response["serverRSDPort"]
              ) else {
            throw RorkDeviceError.protocolViolation(
                "CDTunnel handshake response is missing network parameters."
            )
        }

        return CoreDeviceTunnelConfiguration(
            hostAddress: hostAddress,
            deviceAddress: deviceAddress,
            networkMask: networkMask,
            maximumTransmissionUnit: mtu,
            serviceDiscoveryPort: rsdPort
        )
    }

    /// Reads one complete IPv6 packet using the payload length in its header.
    static func receivePacket(from connection: DeviceConnection) async throws -> Data {
        let header = try await connection.receive(exactly: 40)
        guard header.first.map({ $0 >> 4 }) == 6 else {
            throw RorkDeviceError.protocolViolation(
                "CDTunnel received a packet without an IPv6 header."
            )
        }
        let payloadLength = try Int(header.bigEndianInteger(at: 4, as: UInt16.self))
        let payload = try await connection.receive(exactly: payloadLength)
        return header + payload
    }

    /// Rejects buffers that are not exactly one complete IPv6 packet.
    static func validatePacket(
        _ packet: Data,
        diagnosticName: String
    ) throws {
        guard packet.count >= 40 else {
            throw RorkDeviceError.invalidInput(
                "\(diagnosticName) packet is shorter than the 40-byte IPv6 header."
            )
        }
        guard packet.first.map({ $0 >> 4 }) == 6 else {
            throw RorkDeviceError.invalidInput(
                "\(diagnosticName) only accepts IPv6 packets."
            )
        }

        let payloadLength = try Int(
            packet.bigEndianInteger(at: 4, as: UInt16.self)
        )
        guard packet.count == 40 + payloadLength else {
            throw RorkDeviceError.invalidInput(
                "\(diagnosticName) packet length does not match its IPv6 header."
            )
        }
    }
}

/// Owns one negotiated CDTunnel byte stream and preserves packet boundaries.
///
/// A CDTunnel connection permits one reader and ordered writes concurrently.
/// This wrapper scopes that concurrency guarantee to the packet protocol rather
/// than claiming it for every `DeviceConnection` implementation.
final class CDTunnelConnection: @unchecked Sendable {
    /// Full-duplex stream carrying complete IPv6 packets.
    private let connection: DeviceConnection

    /// Human-readable tunnel name included in packet validation failures.
    private let diagnosticName: String

    /// Coordinator that prevents suspended sends from overlapping on the stream.
    private let writeCoordinator = CDTunnelWriteCoordinator()

    /// Creates a packet connection that owns the supplied byte stream.
    init(
        connection: DeviceConnection,
        diagnosticName: String
    ) {
        self.connection = connection
        self.diagnosticName = diagnosticName
    }

    /// Validates and sends one complete IPv6 packet.
    func sendPacket(_ packet: Data) async throws {
        try CDTunnelProtocol.validatePacket(
            packet,
            diagnosticName: diagnosticName
        )
        try Task.checkCancellation()
        await writeCoordinator.acquire()
        do {
            try Task.checkCancellation()
            try await connection.send(packet)
            await writeCoordinator.release()
        } catch {
            await writeCoordinator.release()
            throw error
        }
    }

    /// Receives one complete IPv6 packet using its header-declared length.
    func receivePacket() async throws -> Data {
        try await CDTunnelProtocol.receivePacket(from: connection)
    }

    /// Closes the owned byte stream.
    func close() {
        connection.close()
    }
}

/// Coordinates exclusive access to one CDTunnel transport write path.
///
/// The coordinator owns no transport object. It only transfers one logical
/// write slot at a time, allowing `CDTunnelConnection` to retain the
/// non-Sendable byte stream while still keeping complete IPv6 packets
/// contiguous across suspension points.
private actor CDTunnelWriteCoordinator {
    /// Whether a caller currently owns the write slot.
    private var isWriteInProgress = false

    /// Callers waiting to acquire the write slot in arrival order.
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until this caller exclusively owns the transport write slot.
    func acquire() async {
        guard isWriteInProgress else {
            isWriteInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    /// Transfers ownership to the next waiter or marks the slot as available.
    func release() {
        guard !writeWaiters.isEmpty else {
            isWriteInProgress = false
            return
        }

        writeWaiters.removeFirst().resume()
    }
}

/// Converts a JSON value to a trimmed, nonempty string.
private func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
