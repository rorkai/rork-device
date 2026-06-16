import Foundation

/// Raw IPv6 packet tunnel opened through CoreDevice's Lockdown service.
///
/// The tunnel starts `com.apple.internal.devicecompute.CoreDeviceProxy`,
/// negotiates the private IPv6 link, and retains that service connection for
/// the lifetime of the instance. It exposes packets rather than service byte
/// streams; applications can attach a userspace network backend or another
/// packet consumer appropriate for their platform.
public final class CoreDeviceTunnel {
    /// Network parameters negotiated with the connected device.
    public let configuration: CoreDeviceTunnelConfiguration

    /// Packet-framed CoreDevice service connection owned by this tunnel.
    private let packetConnection: CDTunnelConnection

    /// Creates a tunnel around an already negotiated service stream.
    private init(
        configuration: CoreDeviceTunnelConfiguration,
        connection: DeviceConnection
    ) {
        self.configuration = configuration
        packetConnection = CDTunnelConnection(
            connection: connection,
            diagnosticName: "CoreDevice tunnel"
        )
    }

    /// Negotiates CoreDevice's packet protocol on an opened service stream.
    ///
    /// The method takes ownership of `connection` immediately. A failed
    /// handshake closes it before propagating the error.
    ///
    /// - Parameters:
    ///   - connection: Stream returned by CoreDeviceProxy.
    ///   - requestedMaximumTransmissionUnit: Largest IPv6 packet size requested
    ///     from the device.
    /// - Returns: An owned packet tunnel with negotiated network parameters.
    static func open(
        over connection: DeviceConnection,
        requestedMaximumTransmissionUnit: UInt16
    ) async throws -> CoreDeviceTunnel {
        do {
            let configuration = try await CDTunnelProtocol
                .negotiateConfiguration(
                    over: connection,
                    requestedMaximumTransmissionUnit:
                        requestedMaximumTransmissionUnit
                )
            return CoreDeviceTunnel(
                configuration: configuration,
                connection: connection
            )
        } catch {
            connection.close()
            throw error
        }
    }

    /// Sends one complete IPv6 packet through the CoreDevice service.
    ///
    /// Concurrent sends are serialized so packet bytes cannot overlap on the
    /// underlying stream.
    ///
    /// - Parameter packet: Complete IPv6 packet including its 40-byte header.
    /// - Throws: `RorkDeviceError.invalidInput` for malformed packet framing, or
    ///   a transport error when the service stream is unavailable.
    public func sendPacket(_ packet: Data) async throws {
        try await packetConnection.sendPacket(packet)
    }

    /// Receives one complete IPv6 packet from the CoreDevice service.
    ///
    /// - Returns: Complete IPv6 packet including its 40-byte header.
    /// - Throws: A protocol or transport error when a complete packet cannot be
    ///   read.
    public func receivePacket() async throws -> Data {
        try await packetConnection.receivePacket()
    }

    /// Closes the CoreDevice service and invalidates pending packet operations.
    ///
    /// Calling this method more than once is safe.
    public func close() {
        packetConnection.close()
    }
}
