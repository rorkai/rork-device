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

    /// Lockdown returned a failure response.
    case lockdown(String)

    /// The device requested secure traffic but no secure-session upgrader was
    /// configured.
    case secureSessionUnsupported

    /// Secure-session setup, certificate parsing, or TLS I/O failed.
    case secureSession(String)

    /// AFC returned a non-zero status code.
    case afcStatus(UInt64)

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
        case let .lockdown(message):
            return "Lockdown error: \(message)"
        case .secureSessionUnsupported:
            return "The device requested a secure Lockdown session, but this client was created without a secure-session upgrader."
        case let .secureSession(message):
            return "Secure session error: \(message)"
        case let .afcStatus(status):
            return "AFC returned status \(status)."
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
