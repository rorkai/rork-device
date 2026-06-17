import Foundation

/// Bidirectional byte stream used by device protocol clients.
///
/// Service clients in this package are transport-agnostic. They only require a
/// connection that can send complete byte buffers, receive exact byte counts,
/// and close when an operation finishes or fails.
public protocol DeviceConnection: AnyObject {
    /// Sends all bytes in `data`.
    ///
    /// Implementations should not return until the full buffer has been written
    /// or an error has been thrown.
    func send(_ data: Data) async throws

    /// Receives exactly `byteCount` bytes unless the connection fails or closes.
    ///
    /// Returning fewer bytes is treated as a protocol error by higher-level
    /// clients, so implementations should accumulate reads internally.
    func receive(exactly byteCount: Int) async throws -> Data

    /// Closes the connection and releases any underlying resources.
    func close()
}

/// Optional capability for transports that can return a short read.
///
/// Socket-backed connections expose this for protocols that can consume
/// currently available bytes without waiting for a larger fixed-size frame.
///
/// Conforming connections support one reader while ordered writes run from
/// another task. This full-duplex guarantee lets forwarding code move bytes in
/// both directions without claiming that every `DeviceConnection` is sendable.
protocol PartialReceiveDeviceConnection: DeviceConnection, Sendable {
    /// Receives at least one byte and at most `byteCount` bytes.
    func receive(upTo byteCount: Int) async throws -> Data
}

/// Transport capable of opening device service connections by port.
///
/// A transport abstracts how bytes reach the device: local usbmux forwarding,
/// direct TCP, a tunnel, or a test double.
public protocol DeviceTransport {
    /// Opens a connection to a device service port.
    ///
    /// The `port` is the device-side port reported by Lockdown, expressed in
    /// host byte order.
    func connect(to port: UInt16) async throws -> DeviceConnection
}

/// Upgrades a connection to the secure mode requested by Lockdown.
///
/// Devices often request SSL/TLS for Lockdown sessions and for services started
/// by Lockdown. This protocol keeps the cryptographic backend injectable so
/// applications can choose the appropriate implementation for their platform.
public protocol SecureSessionUpgrader {
    /// Returns a secure connection using pairing-record credentials.
    ///
    /// The caller retains ownership of `connection` until this method succeeds.
    /// On success, the returned connection owns or wraps the original stream; on
    /// failure, the caller remains responsible for closing the original stream.
    ///
    /// - Parameters:
    ///   - connection: Plain connection that Lockdown asked to secure.
    ///   - pairingRecord: Pairing material containing certificates and keys.
    func upgrade(_ connection: DeviceConnection, pairingRecord: PairingRecord) async throws -> DeviceConnection
}

/// Platform default secure-session upgrader.
///
/// The default delegates to `NIOSecureSessionUpgrader`, which adds TLS to the
/// existing SwiftNIO channel used by the package's built-in transports.
public struct DefaultSecureSessionUpgrader: SecureSessionUpgrader {
    /// Creates the default platform upgrader.
    public init() {}

    /// Adds TLS to an established connection backed by a built-in transport.
    public func upgrade(_ connection: DeviceConnection, pairingRecord: PairingRecord) async throws -> DeviceConnection {
        try await NIOSecureSessionUpgrader().upgrade(
            connection,
            pairingRecord: pairingRecord
        )
    }
}

/// Default secure-session upgrader used when TLS support has not been supplied.
///
/// This type makes unsupported secure sessions fail explicitly instead of
/// silently continuing on an unencrypted connection.
public struct UnsupportedSecureSessionUpgrader: SecureSessionUpgrader {
    /// Creates the default unsupported upgrader.
    public init() {}

    /// Always throws `RorkDeviceError.secureSessionUnsupported`.
    public func upgrade(_ connection: DeviceConnection, pairingRecord: PairingRecord) async throws -> DeviceConnection {
        throw RorkDeviceError.secureSessionUnsupported
    }
}
