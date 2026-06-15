import Foundation
#if canImport(Network)
import Network
#endif

/// Routing policy applied to both sockets used by one remote-pairing session.
///
/// Pair verification and packet transport must follow the same route. Keeping
/// that choice in one value prevents a transport from binding only one of the two
/// connections to a caller-selected interface.
enum RemotePairingTransportRoute {
    /// Lets the operating system choose the route for both connections.
    case systemDefault

    #if canImport(Network)
    /// Requires both connections to use one Network.framework interface.
    case networkInterface(NWInterface)
    #endif
}

/// Protected packet stream and diagnostics returned by a transport.
///
/// The connection is ready for the CDTunnel handshake. Security metadata is
/// optional because not every portable TLS implementation exposes the selected
/// cipher suite through its connection API.
struct RemotePairingTLSConnection {
    /// TLS-protected byte stream connected to the device listener.
    let connection: DeviceConnection

    /// Cipher suite captured after the handshake, when available.
    let cipherSuite: RemotePairingTLSCipherSuite?
}

/// Opens the control and protected streams required by remote pairing.
///
/// The transport owns platform-specific socket routing and TLS-PSK setup.
/// Pair-verification messages and CDTunnel negotiation remain in shared code so
/// adding another platform requires only a transport implementation.
protocol RemotePairingTransport {
    /// Opens the plain TCP stream used for pair verification.
    func openControlConnection(
        to host: String,
        port: UInt16,
        over route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> DeviceConnection

    /// Opens the TLS 1.2 PSK stream allocated by the verified device.
    func openTLSConnection(
        to host: String,
        port: UInt16,
        using preSharedKey: Data,
        over route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> RemotePairingTLSConnection
}

/// Selects the transport implementation bundled for the current platform.
///
/// Keeping selection separate from `RemotePairingTunnel` lets additional
/// transports become the platform default without changing the public API.
enum RemotePairingTransportProvider {
    /// Whether this build contains a transport capable of remote pairing.
    static var isSupported: Bool {
        #if canImport(Network) && canImport(Security)
        true
        #else
        false
        #endif
    }

    /// Creates the transport used by public remote-pairing connection methods.
    ///
    /// - Returns: The platform's bundled remote-pairing transport.
    /// - Throws: `RorkDeviceError.secureSessionUnsupported` when the current
    ///   build does not contain a compatible TLS-PSK implementation.
    static func makeDefault() throws -> any RemotePairingTransport {
        #if canImport(Network) && canImport(Security)
        AppleRemotePairingTransport()
        #else
        throw RorkDeviceError.secureSessionUnsupported
        #endif
    }
}

#if canImport(Network) && canImport(Security)
/// Remote-pairing transport implemented with SwiftNIO and Network.framework.
///
/// SwiftNIO opens the pair-verification stream. Network.framework opens the
/// TLS-PSK packet stream because it provides the required PSK cipher policy and
/// can bind that connection to an `NWInterface`.
struct AppleRemotePairingTransport: RemotePairingTransport {
    /// Opens pair verification through the system route or requested interface.
    func openControlConnection(
        to host: String,
        port: UInt16,
        over route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> DeviceConnection {
        switch route {
        case .systemDefault:
            return try await TCPDeviceConnection.connect(
                to: host,
                port: port,
                timeout: timeout
            )
        case .networkInterface(let interface):
            let interfaceIndex = try Self.socketInterfaceIndex(for: interface)
            return try await TCPDeviceConnection.connect(
                to: host,
                port: port,
                boundToIPv4Interface: interfaceIndex,
                timeout: timeout
            )
        }
    }

    /// Opens the protected packet stream with the route used for pair verification.
    func openTLSConnection(
        to host: String,
        port: UInt16,
        using preSharedKey: Data,
        over route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> RemotePairingTLSConnection {
        let connection: NetworkDeviceConnection
        switch route {
        case .systemDefault:
            connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: port,
                using: preSharedKey,
                timeout: timeout
            )
        case .networkInterface(let interface):
            connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: port,
                using: preSharedKey,
                through: interface,
                timeout: timeout
            )
        }
        return RemotePairingTLSConnection(
            connection: connection,
            cipherSuite: connection.tlsCipherSuite
        )
    }

    /// Converts an `NWInterface` index into the socket-option representation.
    private static func socketInterfaceIndex(
        for interface: NWInterface
    ) throws -> UInt32 {
        guard interface.index > 0,
              let interfaceIndex = UInt32(exactly: interface.index) else {
            throw RorkDeviceError.invalidInput(
                "Remote pairing requires a valid network interface index."
            )
        }
        return interfaceIndex
    }
}
#endif
