import Foundation

/// A machine-readable description of why a device operation failed.
///
/// Applications that drive the `rorkdevice` CLI as a subprocess cannot see
/// the typed errors behind its human-readable stderr text. This value carries
/// a stable `code` derived from the error's type and case, so a supervisor can
/// branch on the failure without matching English messages. The CLI prints it
/// as JSON on failure when asked to, the tunnel agent attaches it to failed
/// replies and lifecycle events, and Swift callers can derive it from any
/// thrown error.
///
/// Codes are part of the wire contract: an existing code keeps its meaning,
/// and new codes may appear in later releases, so consumers must treat a code
/// they do not recognize like ``Code/unknown``.
public struct RorkDeviceFailure: Equatable, Sendable, Encodable {
    /// Stable identifier of a failure class.
    public enum Code: String, CaseIterable, Equatable, Sendable, Encodable {
        /// No attached device matched the requested selection.
        case deviceNotFound = "device-not-found"

        /// The device must be unlocked before the request can proceed.
        case deviceLocked = "device-locked"

        /// The peer closed or reset the connection.
        case connectionClosed = "connection-closed"

        /// The device reset one RemoteXPC HTTP/2 stream.
        case streamReset = "stream-reset"

        /// An operation exceeded its deadline.
        case timeout = "timeout"

        /// The served tunnel stayed down past a request's patience.
        case tunnelUnavailable = "tunnel-unavailable"

        /// The device does not recognize the presented remote-pairing identity.
        case trustNotRecognized = "trust-not-recognized"

        /// The device ended manual pair setup without returning pairing data,
        /// which happens when the user declines the Trust prompt or does not
        /// finish the passcode approval.
        case pairingApprovalIncomplete = "pairing-approval-incomplete"

        /// The device is waiting for the user to answer the Trust dialog.
        case awaitingTrust = "awaiting-trust"

        /// The user rejected the Trust dialog.
        case trustDenied = "trust-denied"

        /// The device did not resolve its Trust dialog before the deadline.
        case trustTimeout = "trust-timeout"

        /// Device policy prohibits pairing over the current connection.
        case pairingProhibited = "pairing-prohibited"

        /// Lockdown rejected pairing for a reason not modeled separately.
        case pairingRejected = "pairing-rejected"

        /// Remote-pairing signature or setup-code authentication failed.
        case remotePairingAuthenticationFailed = "remote-pairing-authentication-failed"

        /// The device asks the host to wait before pairing again.
        case remotePairingBackoff = "remote-pairing-backoff"

        /// The device cannot store another remote-pairing identity.
        case remotePairingCapacityReached = "remote-pairing-capacity-reached"

        /// The device stopped accepting remote-pairing authentication attempts.
        case remotePairingAttemptsExhausted = "remote-pairing-attempts-exhausted"

        /// The device rejected remote pairing for an unspecified or
        /// unrecognized reason.
        case remotePairingRejected = "remote-pairing-rejected"

        /// The command line or an API argument was invalid.
        case invalidInput = "invalid-input"

        /// A pairing record is missing required fields or is malformed.
        case invalidPairingRecord = "invalid-pairing-record"

        /// A socket, tunnel, or forwarding transport failed.
        case transport = "transport"

        /// The peer sent malformed or unexpected protocol data.
        case protocolViolation = "protocol-violation"

        /// Lockdown returned a failure response.
        case lockdown = "lockdown"

        /// The secure session could not be established or failed.
        case secureSession = "secure-session"

        /// AFC returned a non-zero status.
        case afc = "afc"

        /// Heartbeat returned malformed data or reported device sleep.
        case heartbeat = "heartbeat"

        /// InstallationProxy reported an operation error.
        case installationFailed = "installation-failed"

        /// MISAgent returned a non-zero status.
        case misagent = "misagent"

        /// A requested local port is already in use.
        case portUnavailable = "port-unavailable"

        /// The operation was cancelled.
        case cancelled = "cancelled"

        /// The failure has no more specific classification.
        case unknown = "unknown"
    }

    /// Typed context for a failure, encoded only when present.
    public struct Details: Equatable, Sendable, Encodable {
        /// Identifier of the device the failure concerns.
        public var deviceIdentifier: String?

        /// HTTP/2 stream the device reset.
        public var streamIdentifier: UInt32?

        /// HTTP/2 error code the device sent with `RST_STREAM`.
        public var http2ErrorCode: UInt32?

        /// Numeric status reported by AFC or MISAgent.
        public var status: Int64?

        /// Raw error code reported by the device, such as an InstallationProxy
        /// error or a Lockdown pairing error identifier.
        public var deviceErrorCode: String?

        /// Numeric remote-pairing rejection code the device sent.
        public var rejectionCode: UInt8?

        /// How long the device asks the host to wait before retrying.
        public var retryAfterMilliseconds: Int64?

        /// Local port that could not be bound.
        public var port: UInt16?

        /// Creates details from the fields that apply.
        public init(
            deviceIdentifier: String? = nil,
            streamIdentifier: UInt32? = nil,
            http2ErrorCode: UInt32? = nil,
            status: Int64? = nil,
            deviceErrorCode: String? = nil,
            rejectionCode: UInt8? = nil,
            retryAfterMilliseconds: Int64? = nil,
            port: UInt16? = nil
        ) {
            self.deviceIdentifier = deviceIdentifier
            self.streamIdentifier = streamIdentifier
            self.http2ErrorCode = http2ErrorCode
            self.status = status
            self.deviceErrorCode = deviceErrorCode
            self.rejectionCode = rejectionCode
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.port = port
        }

        /// Whether no field is set, in which case the failure omits details.
        var isEmpty: Bool {
            self == Details()
        }
    }

    /// Stable failure class.
    public let code: Code

    /// Human-readable description, identical to the error's CLI text.
    public let message: String

    /// Typed context for the failure, when the error carries any.
    public let details: Details?

    /// Stored as an array because a struct cannot contain itself directly.
    private let causes: [RorkDeviceFailure]

    /// The earlier failure this one reports, such as the tunnel loss that
    /// left a request without a session.
    public var cause: RorkDeviceFailure? {
        causes.first
    }

    /// Creates a failure from its parts.
    public init(
        code: Code,
        message: String,
        details: Details? = nil,
        cause: RorkDeviceFailure? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details.flatMap { $0.isEmpty ? nil : $0 }
        self.causes = cause.map { [$0] } ?? []
    }

    /// Classifies any thrown error.
    ///
    /// Errors from this package classify by type and case. Anything else is
    /// ``Code/unknown`` with its description as the message.
    public init(_ error: any Error) {
        if let convertible = error as? any RorkDeviceFailureConvertible {
            self = convertible.failure
        } else if error is CancellationError {
            self.init(code: .cancelled, message: "The operation was cancelled.")
        } else {
            self.init(code: .unknown, message: String(describing: error))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
        case cause
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(cause, forKey: .cause)
    }
}

/// An error that knows its machine-readable failure classification.
///
/// Conforming types map every case explicitly, so adding a case forces a
/// decision about how supervisors should classify it.
public protocol RorkDeviceFailureConvertible: Error {
    /// The machine-readable classification of this error.
    var failure: RorkDeviceFailure { get }
}

extension RorkDeviceError: RorkDeviceFailureConvertible {
    public var failure: RorkDeviceFailure {
        RorkDeviceFailure(
            code: failureCode,
            message: description,
            details: failureDetails,
            cause: failureCause
        )
    }

    private var failureCode: RorkDeviceFailure.Code {
        switch self {
        case .invalidInput:
            return .invalidInput
        case .invalidPairingRecord:
            return .invalidPairingRecord
        case .deviceNotFound:
            return .deviceNotFound
        case .deviceLocked:
            return .deviceLocked
        case .connectionClosed, .connectionReset:
            return .connectionClosed
        case .timedOut:
            return .timeout
        case .tunnelUnavailable:
            return .tunnelUnavailable
        case let .remoteServiceCheckIn(_, _, _, underlying):
            // The check-in wrapper adds only context, so supervisors see the
            // failure that ended the connection, such as a closed stream they
            // retry on.
            return underlying.code == .unknown ? .transport : underlying.code
        case .transport:
            return .transport
        case .protocolViolation:
            return .protocolViolation
        case .remoteXPCStreamReset:
            return .streamReset
        case .lockdown:
            return .lockdown
        case .secureSessionUnsupported, .secureSession:
            return .secureSession
        case let .remotePairing(rejection):
            return rejection.failureCode
        case .remotePairingApprovalIncomplete:
            return .pairingApprovalIncomplete
        case .afcStatus:
            return .afc
        case .heartbeat:
            return .heartbeat
        case .installationProxy:
            return .installationFailed
        case .misagentStatus:
            return .misagent
        }
    }

    private var failureDetails: RorkDeviceFailure.Details? {
        switch self {
        case let .deviceNotFound(identifier, _):
            return .init(deviceIdentifier: identifier)
        case let .remoteXPCStreamReset(streamIdentifier, errorCode):
            return .init(
                streamIdentifier: streamIdentifier,
                http2ErrorCode: errorCode
            )
        case let .remotePairing(rejection):
            return rejection.failureDetails
        case let .afcStatus(status):
            return .init(status: Int64(clamping: status))
        case let .installationProxy(error):
            return .init(deviceErrorCode: error.code.rawValue)
        case let .misagentStatus(status):
            return .init(status: Int64(status))
        case .invalidInput, .invalidPairingRecord, .deviceLocked,
            .connectionClosed, .connectionReset, .timedOut,
            .tunnelUnavailable, .remoteServiceCheckIn, .transport, .protocolViolation, .lockdown,
            .secureSessionUnsupported, .secureSession,
            .remotePairingApprovalIncomplete, .heartbeat:
            return nil
        }
    }

    private var failureCause: RorkDeviceFailure? {
        switch self {
        case let .tunnelUnavailable(lastFailure):
            return lastFailure
        case let .remoteServiceCheckIn(_, _, _, underlying):
            return underlying
        default:
            return nil
        }
    }
}

extension RemotePairingRejection {
    fileprivate var failureCode: RorkDeviceFailure.Code {
        switch self {
        case .unknownPeer:
            return .trustNotRecognized
        case .authentication:
            return .remotePairingAuthenticationFailed
        case .backoff:
            return .remotePairingBackoff
        case .maximumPeers:
            return .remotePairingCapacityReached
        case .maximumAttempts:
            return .remotePairingAttemptsExhausted
        case .unknown, .unrecognized:
            return .remotePairingRejected
        }
    }

    fileprivate var failureDetails: RorkDeviceFailure.Details? {
        switch self {
        case let .backoff(retryDelay?):
            let components = retryDelay.components
            return .init(
                retryAfterMilliseconds: components.seconds * 1_000
                    + components.attoseconds / 1_000_000_000_000_000
            )
        case let .unrecognized(code):
            return .init(rejectionCode: code)
        case .backoff(nil), .unknown, .authentication, .unknownPeer,
            .maximumPeers, .maximumAttempts:
            return nil
        }
    }
}

extension LockdownPairingError: RorkDeviceFailureConvertible {
    public var failure: RorkDeviceFailure {
        let message = errorDescription ?? String(describing: self)
        switch self {
        case .userConfirmationRequired:
            return .init(code: .awaitingTrust, message: message)
        case .userDenied:
            return .init(code: .trustDenied, message: message)
        case .deviceLocked:
            return .init(code: .deviceLocked, message: message)
        case .prohibited:
            return .init(code: .pairingProhibited, message: message)
        case .timedOut:
            return .init(code: .trustTimeout, message: message)
        case let .rejected(identifier):
            return .init(
                code: .pairingRejected,
                message: message,
                details: .init(deviceErrorCode: identifier)
            )
        }
    }
}

#if canImport(NIOPosix) && canImport(RorkDeviceLwIP) && !os(WASI)
extension CoreDeviceUserspaceGateway.PortUnavailableError: RorkDeviceFailureConvertible {
    public var failure: RorkDeviceFailure {
        RorkDeviceFailure(
            code: .portUnavailable,
            message: description,
            details: .init(port: port)
        )
    }
}
#endif
