import Foundation

/// Network configuration negotiated for a remote-pairing tunnel.
///
/// The host and device addresses define the private IPv6 link carried by
/// `RemotePairingTunnel`. Applications typically apply these values to a packet
/// tunnel interface, then connect to Remote Service Discovery at
/// `deviceAddress` and `serviceDiscoveryPort`.
public struct RemotePairingTunnelConfiguration: Equatable, Sendable {
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
    /// forwarding larger packets because `RemotePairingTunnel` does not perform
    /// fragmentation.
    public let maximumTransmissionUnit: UInt16

    /// Port of the device's Remote Service Discovery endpoint.
    ///
    /// The endpoint is available at `deviceAddress` only through the active
    /// packet tunnel. Pass it to
    /// `DeviceClient.connect(toRemoteServicesAt:port:label:)`.
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
    ) async throws -> RemotePairingTunnelConfiguration {
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

        return RemotePairingTunnelConfiguration(
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
}

/// Converts a JSON value to a trimmed, nonempty string.
private func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
