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

    /// No attached device matched the requested selection.
    ///
    /// `identifier` is the requested device identifier, or nil when the
    /// caller asked for the first available device. `usbOnly` records that
    /// only cable-attached devices were eligible.
    case deviceNotFound(identifier: String?, usbOnly: Bool)

    /// Lockdown refused `request` because the device is locked with a
    /// passcode.
    case deviceLocked(request: String)

    /// The peer closed the connection. The message names the connection.
    case connectionClosed(String)

    /// This side closed the connection, for example while a tunnel cycle
    /// was torn down, and an operation still used it. The message names the
    /// connection.
    case localConnectionClosed(String)

    /// The peer reset the connection. The message preserves the platform's
    /// diagnostic detail.
    case connectionReset(String)

    /// An operation exceeded its deadline.
    case timedOut(String)

    /// The served tunnel stayed down past a request's patience.
    ///
    /// `lastFailure` is the most recent reason the tunnel was lost or failed
    /// to re-establish, when one was reported.
    case tunnelUnavailable(lastFailure: RorkDeviceFailure?)

    /// A transport step such as connecting to or checking in with a service
    /// failed.
    ///
    /// `context` names the step and `underlying` keeps the classification of
    /// the failure that ended it, such as a closed connection, a timeout, or
    /// a reset stream.
    case transportStep(context: String, underlying: RorkDeviceFailure)

    /// A socket, tunnel, or forwarding transport failed.
    case transport(String)

    /// The usbmux daemon answered `operation` with a non-zero result code.
    ///
    /// The same number means different things per operation, so only
    /// ``USBMuxOperation/connect`` answered with
    /// ``USBMuxOperation/connectBadDeviceResult`` means the device detached.
    case usbmuxResult(operation: USBMuxOperation, code: Int)

    /// The peer returned malformed or unexpected protocol data.
    case protocolViolation(String)

    /// The device's Remote Service Discovery directory does not list the
    /// named service, for example a CoreDevice service that only appears once
    /// the Developer Disk Image is mounted.
    case serviceNotAdvertised(String)

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

    /// The device ended manual pair setup without returning pairing data.
    ///
    /// The device closes the exchange this way both when the user declines
    /// the Trust prompt and when the passcode approval is not finished; the
    /// two are indistinguishable on the wire.
    case remotePairingApprovalIncomplete

    /// AFC returned a non-zero status code.
    case afcStatus(UInt64)

    /// Heartbeat returned malformed data or reported device sleep.
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
        case let .deviceNotFound(_, usbOnly):
            return usbOnly ? "No matching USB device found." : "No matching device found."
        case let .deviceLocked(request):
            return "Lockdown error: \(request) failed: PasswordProtected"
        case let .connectionClosed(message), let .localConnectionClosed(message):
            return "Transport error: \(message)"
        case let .connectionReset(message):
            return "Transport error: \(message)"
        case let .timedOut(message):
            return message
        case let .tunnelUnavailable(lastFailure):
            guard let lastFailure else {
                return "Transport error: The tunnel is not ready and no session became available in time."
            }
            return "Transport error: The tunnel is not ready (last failure: \(lastFailure.message)) and no session became available in time."
        case let .transportStep(context, underlying):
            return "Transport error: \(context): \(underlying.message)"
        case let .transport(message):
            return "Transport error: \(message)"
        case let .usbmuxResult(operation, code):
            return "Transport error: usbmux \(operation.rawValue) failed with code \(code)."
        case let .protocolViolation(message):
            return "Protocol violation: \(message)"
        case let .serviceNotAdvertised(serviceName):
            return "Protocol violation: Remote service directory does not advertise \(serviceName)."
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
        case .remotePairingApprovalIncomplete:
            return "Protocol violation: Remote pairing response is missing pairing data."
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

/// A usbmux control request whose result code the client checks.
public enum USBMuxOperation: String, Equatable, Hashable, Sendable {
    case connect = "Connect"
    case listen = "Listen"
    case readPairRecord = "ReadPairRecord"
    case savePairRecord = "SavePairRecord"
    case deletePairRecord = "DeletePairRecord"

    /// usbmux answers `Connect` with this result (BadDevice) when the device
    /// is no longer attached. Pair-record requests reuse the number for a
    /// missing record, so it means a detach only for ``connect``.
    public static let connectBadDeviceResult = 2

    /// Whether `code`, answered to this request, means the device detached.
    func meansDeviceDetached(_ code: Int) -> Bool {
        self == .connect && code == Self.connectBadDeviceResult
    }
}
