import Foundation

/// Device transport backed by CoreDevice's local userspace gateway.
///
/// Each accepted connection begins with a 20-byte destination preamble: the
/// device's 16-byte IPv6 address followed by its port as a 32-bit little-endian
/// integer. After that selector, the gateway exposes the requested device
/// service as a normal byte stream.
public struct CoreDeviceUserspaceTransport: DeviceTransport, Sendable {
    /// Device IPv6 address assigned by the active CoreDevice tunnel.
    public let deviceAddress: String

    /// Host running the local forwarding gateway.
    public let gatewayHost: String

    /// TCP port accepting destination-prefixed connections.
    public let gatewayPort: UInt16

    /// Maximum duration for opening each gateway connection.
    public let connectionTimeout: Duration

    /// Parsed device address retained so invalid routes cannot be represented.
    private let deviceAddressBytes: Data

    /// Creates a transport for one active CoreDevice userspace tunnel.
    ///
    /// - Parameters:
    ///   - deviceAddress: Device IPv6 address reported by CoreDevice.
    ///   - gatewayHost: Host running the userspace gateway. Use loopback when
    ///     the gateway runs on the same machine.
    ///   - gatewayPort: Local TCP port reported for the userspace gateway.
    ///   - connectionTimeout: Maximum duration for opening a gateway connection.
    /// - Throws: `RorkDeviceError.invalidInput` when the device address, host,
    ///   or gateway port cannot identify a usable route.
    public init(
        deviceAddress: String,
        gatewayHost: String = "127.0.0.1",
        gatewayPort: UInt16,
        connectionTimeout: Duration = .seconds(8)
    ) throws {
        let deviceAddress = deviceAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let gatewayHost = gatewayHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !gatewayHost.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace transport requires a gateway host."
            )
        }
        guard gatewayPort > 0 else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace transport requires a nonzero gateway port."
            )
        }

        self.deviceAddress = deviceAddress
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
        self.connectionTimeout = connectionTimeout
        deviceAddressBytes = try ipv6AddressBytes(
            deviceAddress,
            invalidMessage:
                "CoreDevice userspace transport requires a valid IPv6 device address."
        )
    }

    /// Opens a gateway-forwarded connection to one device service port.
    public func connect(to port: UInt16) async throws -> DeviceConnection {
        guard port > 0 else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace transport requires a nonzero device port."
            )
        }
        let connection = try await TCPDeviceConnection.connect(
            to: gatewayHost,
            port: gatewayPort,
            timeout: connectionTimeout
        )
        do {
            var preamble = deviceAddressBytes
            preamble.appendLittleEndian(UInt32(port))
            try await connection.send(preamble)
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Encodes the destination selector consumed by the userspace gateway.
    static func destinationPreamble(
        address: String,
        port: UInt16
    ) throws -> Data {
        guard port > 0 else {
            throw RorkDeviceError.invalidInput(
                "CoreDevice userspace transport requires a nonzero device port."
            )
        }

        var preamble = try ipv6AddressBytes(
            address,
            invalidMessage:
                "CoreDevice userspace transport requires a valid IPv6 device address."
        )
        preamble.appendLittleEndian(UInt32(port))
        return preamble
    }
}
