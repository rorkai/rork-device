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
public struct RorkDeviceFailure: Equatable, Sendable, Codable {
    /// Stable identifier of a failure class.
    public enum Code: String, CaseIterable, Equatable, Sendable, Codable {
        /// No attached device matched the requested selection.
        case deviceNotFound = "device-not-found"

        /// The device was found but detached before a connection to it
        /// opened: usbmux answered `Connect` with its bad-device result.
        case deviceDisconnected = "device-disconnected"

        /// The device must be unlocked before the request can proceed.
        case deviceLocked = "device-locked"

        /// The connection closed: the peer closed or reset it, or this side
        /// tore it down while an operation was still using it.
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

        /// The device does not advertise a required service, named in
        /// `details.serviceName`. CoreDevice services such as
        /// `com.apple.coredevice.appservice` appear only once the Developer
        /// Disk Image is mounted.
        case serviceNotAdvertised = "service-not-advertised"

        /// Lockdown returned a failure response.
        case lockdown = "lockdown"

        /// The secure session could not be established or failed.
        case secureSession = "secure-session"

        /// AFC returned a non-zero status.
        case afc = "afc"

        /// Heartbeat returned malformed data or reported device sleep.
        case heartbeat = "heartbeat"

        /// InstallationProxy reported an operation error not classified more
        /// specifically.
        case installationFailed = "installation-failed"

        /// The device already holds the maximum number of apps signed with
        /// free developer profiles.
        case appLimitReached = "app-limit-reached"

        /// The device rejected the app because no valid provisioning profile
        /// authorizes the executable on it.
        case provisioningProfileRejected = "provisioning-profile-rejected"

        /// The app requires a newer OS version than the device runs.
        case osVersionTooLow = "os-version-too-low"

        /// MISAgent returned a non-zero status.
        case misagent = "misagent"

        /// A requested local port is already in use.
        case portUnavailable = "port-unavailable"

        /// The operation was cancelled.
        case cancelled = "cancelled"

        /// The failure has no more specific classification.
        case unknown = "unknown"

        /// Decodes a code, reading one from a newer release as ``unknown``
        /// so consumers never fail on a code added after they were built.
        public init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: rawValue) ?? .unknown
        }
    }

    /// Typed context for a failure, encoded only when present.
    public struct Details: Equatable, Sendable, Codable {
        /// Identifier of the device the failure concerns.
        public var deviceIdentifier: String?

        /// HTTP/2 stream the device reset.
        public var streamIdentifier: UInt32?

        /// HTTP/2 error code the device sent with `RST_STREAM`.
        public var http2ErrorCode: UInt32?

        /// Numeric status reported by AFC, MISAgent, or usbmux. Its meaning
        /// depends on `code`.
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

        /// Device service the failure concerns.
        public var serviceName: String?

        /// MobileInstallation result code behind an InstallationProxy error,
        /// such as 3892346901 (`0xE8008015`).
        public var installationResultCode: UInt32?

        /// Creates details from the fields that apply.
        public init(
            deviceIdentifier: String? = nil,
            streamIdentifier: UInt32? = nil,
            http2ErrorCode: UInt32? = nil,
            status: Int64? = nil,
            deviceErrorCode: String? = nil,
            rejectionCode: UInt8? = nil,
            retryAfterMilliseconds: Int64? = nil,
            port: UInt16? = nil,
            serviceName: String? = nil,
            installationResultCode: UInt32? = nil
        ) {
            self.deviceIdentifier = deviceIdentifier
            self.streamIdentifier = streamIdentifier
            self.http2ErrorCode = http2ErrorCode
            self.status = status
            self.deviceErrorCode = deviceErrorCode
            self.rejectionCode = rejectionCode
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.port = port
            self.serviceName = serviceName
            self.installationResultCode = installationResultCode
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

    /// Decodes a failure, reading unknown codes at any depth as ``Code/unknown``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            code: try container.decode(Code.self, forKey: .code),
            message: try container.decode(String.self, forKey: .message),
            details: try container.decodeIfPresent(Details.self, forKey: .details),
            cause: try container.decodeIfPresent(RorkDeviceFailure.self, forKey: .cause)
        )
    }

    /// Encodes `code` and `message`, and `details` and `cause` only when set.
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
        case .connectionClosed, .localConnectionClosed, .connectionReset:
            return .connectionClosed
        case .timedOut:
            return .timeout
        case .tunnelUnavailable:
            return .tunnelUnavailable
        case let .transportStep(_, underlying):
            // The step adds only context, so supervisors see the failure
            // that ended it, such as a closed stream they retry on.
            return underlying.code == .unknown ? .transport : underlying.code
        case .transport:
            return .transport
        case let .usbmuxResult(operation, code):
            return operation.meansDeviceDetached(code) ? .deviceDisconnected : .transport
        case .protocolViolation:
            return .protocolViolation
        case .serviceNotAdvertised:
            return .serviceNotAdvertised
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
        case let .installationProxy(error):
            return error.failureCode
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
        case let .transportStep(_, underlying):
            // The code is the underlying one, so its details travel with it.
            return underlying.details
        case let .afcStatus(status):
            return .init(status: Int64(clamping: status))
        case let .installationProxy(error):
            return .init(
                deviceErrorCode: error.code.rawValue,
                installationResultCode: error.resultCode
            )
        case let .usbmuxResult(_, code):
            return .init(status: Int64(code))
        case let .serviceNotAdvertised(serviceName):
            return .init(serviceName: serviceName)
        case let .misagentStatus(status):
            return .init(status: Int64(status))
        case .invalidInput, .invalidPairingRecord, .deviceLocked,
            .connectionClosed, .localConnectionClosed, .connectionReset, .timedOut,
            .tunnelUnavailable, .transport, .protocolViolation, .lockdown,
            .secureSessionUnsupported, .secureSession,
            .remotePairingApprovalIncomplete, .heartbeat:
            return nil
        }
    }

    private var failureCause: RorkDeviceFailure? {
        switch self {
        case let .tunnelUnavailable(lastFailure):
            return lastFailure
        case let .transportStep(_, underlying):
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
            return .init(retryAfterMilliseconds: clampedMilliseconds(of: retryDelay))
        case let .unrecognized(code):
            return .init(rejectionCode: code)
        case .backoff(nil), .unknown, .authentication, .unknownPeer,
            .maximumPeers, .maximumAttempts:
            return nil
        }
    }
}

/// Whole milliseconds in `duration`, saturating instead of trapping for
/// device-supplied delays too large to represent.
private func clampedMilliseconds(of duration: Duration) -> Int64 {
    let components = duration.components
    let (milliseconds, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else {
        return components.seconds < 0 ? .min : .max
    }
    let (total, sumOverflow) = milliseconds.addingReportingOverflow(
        components.attoseconds / 1_000_000_000_000_000
    )
    return sumOverflow ? .max : total
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

extension InstallationError {
    /// Classifies by the error and result codes the device sent, never by
    /// the description's wording.
    fileprivate var failureCode: RorkDeviceFailure.Code {
        if code == .deviceOSVersionTooLow {
            return .osVersionTooLow
        }
        switch resultCode {
        case Self.freeDeveloperAppLimitResult:
            return .appLimitReached
        case Self.missingProvisioningProfileResult:
            return .provisioningProfileRejected
        default:
            return .installationFailed
        }
    }
}
