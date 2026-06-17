import Foundation

/// Structured error type used by the public library and CLI.
///
/// Errors are grouped by protocol layer so callers can decide whether a failure
/// is user input, transport reachability, malformed peer data, or a device
/// service rejection.
public enum RorkDeviceError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    /// A required user input or API argument was invalid before any device
    /// protocol request was sent.
    case invalidInput(String)

    /// A pairing record is missing required fields or contains invalid data.
    case invalidPairingRecord(String)

    /// A socket, tunnel, or forwarding transport failed.
    case transport(String)

    /// The peer returned malformed or unexpected protocol data.
    case protocolViolation(String)

    /// The peer terminated one RemoteXPC HTTP/2 stream and supplied the
    /// protocol error code carried by `RST_STREAM`.
    case remoteXPCStreamReset(
        streamIdentifier: UInt32,
        errorCode: UInt32
    )

    /// Lockdown returned a failure response.
    case lockdown(String)

    /// The requested connection requires a secure-session backend that is not
    /// available in the current build.
    case secureSessionUnsupported

    /// Secure-session setup, certificate parsing, or TLS I/O failed.
    case secureSession(String)

    /// The device rejected a remote-pairing protocol request.
    case remotePairing(RemotePairingRejection)

    /// AFC returned a non-zero status code.
    case afcStatus(UInt64)

    /// Heartbeat returned malformed data, timed out, or reported device sleep.
    case heartbeat(String)

    /// InstallationProxy returned an operation error.
    case installationProxy(InstallationError)

    /// MISAgent returned a non-zero status code.
    case misagentStatus(Int)

    /// Human-readable error description suitable for CLI output and logs.
    public var description: String {
        switch self {
        case let .invalidInput(message):
            return message
        case let .invalidPairingRecord(message):
            return "Invalid pairing record: \(message)"
        case let .transport(message):
            return "Transport error: \(message)"
        case let .protocolViolation(message):
            return "Protocol violation: \(message)"
        case let .remoteXPCStreamReset(streamIdentifier, errorCode):
            return "RemoteXPC reset HTTP/2 stream \(streamIdentifier) with error code \(errorCode)."
        case let .lockdown(message):
            return "Lockdown error: \(message)"
        case .secureSessionUnsupported:
            return "The requested device connection requires a secure-session backend that is unavailable in this build."
        case let .secureSession(message):
            return "Secure session error: \(message)"
        case let .remotePairing(rejection):
            return rejection.description
        case let .afcStatus(status):
            return "AFC returned status \(status)."
        case let .heartbeat(message):
            return "Heartbeat error: \(message)"
        case let .installationProxy(error):
            return "InstallationProxy \(error)"
        case let .misagentStatus(status):
            return "MISAgent returned status \(status)."
        }
    }

    /// Localized error text surfaced by Swift apps, Objective-C `NSError`
    /// bridges, and command-line tools that use `localizedDescription`.
    public var errorDescription: String? {
        description
    }
}
