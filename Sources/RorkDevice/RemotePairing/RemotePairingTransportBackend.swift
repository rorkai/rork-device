import Foundation
#if canImport(Network)
import Network
#endif

/// Routing policy applied to both sockets used by one remote-pairing session.
///
/// Pair verification and packet transport must follow the same route. Keeping
/// that choice in one value prevents a backend from binding only one of the two
/// connections to a caller-selected interface.
enum RemotePairingTransportRoute {
    /// Lets the operating system choose the route for both connections.
    case systemDefault

    #if canImport(Network)
    /// Requires both connections to use one Network.framework interface.
    case networkInterface(NWInterface)
    #endif
}

/// Protected packet stream and diagnostics returned by a transport backend.
///
/// The connection is ready for the CDTunnel handshake. Security metadata is
/// optional because not every portable TLS implementation exposes the selected
/// cipher suite through its connection API.
struct RemotePairingTLSConnection {
    /// TLS-protected byte stream connected to the device listener.
    let connection: DeviceConnection

    /// IANA cipher description captured after the handshake, when available.
    let cipherSuite: String?
}

/// Opens the control and protected streams required by remote pairing.
///
/// The backend owns platform-specific socket routing and TLS-PSK setup.
/// Pair-verification messages and CDTunnel negotiation remain in the shared
/// protocol layer so future platform implementations only replace transport.
protocol RemotePairingTransportBackend {
    /// Whether this backend can establish remote-pairing sessions in this build.
    var isAvailable: Bool { get }

    /// Opens the plain TCP stream used for pair verification.
    func openControlConnection(
        to host: String,
        port: UInt16,
        route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> DeviceConnection

    /// Opens the TLS 1.2 PSK stream allocated by the verified device.
    func openTLSConnection(
        to host: String,
        port: UInt16,
        preSharedKey: Data,
        route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> RemotePairingTLSConnection
}

/// Selects the transport implementation bundled for the current platform.
///
/// Keeping selection separate from `RemotePairingTunnel` lets additional
/// backends become the platform default without changing the public tunnel API.
enum RemotePairingTransportBackendProvider {
    /// Backend used by public remote-pairing connection methods.
    static var platformDefault: any RemotePairingTransportBackend {
        #if canImport(Network) && canImport(Security)
        AppleRemotePairingTransportBackend()
        #else
        UnsupportedRemotePairingTransportBackend()
        #endif
    }
}

#if canImport(Network) && canImport(Security)
/// Remote-pairing transport implemented with SwiftNIO and Network.framework.
///
/// SwiftNIO opens the pair-verification stream. Network.framework opens the
/// TLS-PSK packet stream because it provides the required PSK cipher policy and
/// can bind that connection to an `NWInterface`.
struct AppleRemotePairingTransportBackend: RemotePairingTransportBackend {
    /// Apple networking frameworks provide every capability used by the backend.
    let isAvailable = true

    /// Opens pair verification through the system route or requested interface.
    func openControlConnection(
        to host: String,
        port: UInt16,
        route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> DeviceConnection {
        switch route {
        case .systemDefault:
            return try await TCPDeviceConnection.connect(
                to: host,
                port: port,
                timeout: timeout
            )
        case let .networkInterface(interface):
            let interfaceIndex = try validatedInterfaceIndex(interface)
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
        preSharedKey: Data,
        route: RemotePairingTransportRoute,
        timeout: Duration
    ) async throws -> RemotePairingTLSConnection {
        let connection: NetworkDeviceConnection
        switch route {
        case .systemDefault:
            connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: port,
                preSharedKey: preSharedKey,
                timeout: timeout
            )
        case let .networkInterface(interface):
            connection = try await NetworkDeviceConnection.connect(
                to: host,
                port: port,
                preSharedKey: preSharedKey,
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
    private func validatedInterfaceIndex(_ interface: NWInterface) throws -> UInt32 {
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

/// Placeholder backend used when no remote-pairing TLS implementation is built.
///
/// Public connection methods reject this backend before opening either socket.
/// Its methods still fail explicitly so direct internal use cannot fall back to
/// an unprotected or partially initialized connection.
struct UnsupportedRemotePairingTransportBackend: RemotePairingTransportBackend {
    /// No compatible TLS-PSK transport is present in this build.
    let isAvailable = false

    /// Rejects pair-verification setup on unsupported platforms.
    func openControlConnection(
        to _: String,
        port _: UInt16,
        route _: RemotePairingTransportRoute,
        timeout _: Duration
    ) async throws -> DeviceConnection {
        throw RorkDeviceError.secureSessionUnsupported
    }

    /// Rejects protected packet-stream setup on unsupported platforms.
    func openTLSConnection(
        to _: String,
        port _: UInt16,
        preSharedKey _: Data,
        route _: RemotePairingTransportRoute,
        timeout _: Duration
    ) async throws -> RemotePairingTLSConnection {
        throw RorkDeviceError.secureSessionUnsupported
    }
}
