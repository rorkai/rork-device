import Foundation

/// Stable metadata and error identifiers for the tunnel agent's NDJSON protocol.
public enum TunnelAgentProtocol {
    /// Protocol version implemented by this agent.
    public static let currentVersion = 1

    /// Protocol versions accepted when a supervisor sends `protocolVersion`.
    public static let supportedVersions = [currentVersion]

    /// Open failure identifier carried by unsuccessful agent replies.
    public struct ErrorCode:
        RawRepresentable,
        Hashable,
        Codable,
        Sendable
    {
        /// Stable lower-snake-case value carried on the wire.
        public let rawValue: String

        /// Preserves known and future protocol error codes.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Decodes one error-code string without rejecting future values.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(String.self)
        }

        /// Encodes the raw protocol value as one JSON string.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// The input line could not be decoded as a request envelope.
        public static let malformedRequest = Self(rawValue: "malformed_request")

        /// The supervisor requested a protocol version the agent cannot serve.
        public static let unsupportedProtocolVersion = Self(
            rawValue: "unsupported_protocol_version"
        )

        /// Another active operation already owns the request identifier.
        public static let duplicateRequestID = Self(
            rawValue: "duplicate_request_id"
        )

        /// No registered operation matches the requested name.
        public static let unknownOperation = Self(rawValue: "unknown_operation")

        /// The supervisor or agent shutdown cancelled the operation.
        public static let cancelled = Self(rawValue: "cancelled")

        /// No active operation matches the requested cancellation target.
        public static let cancellationTargetNotFound = Self(
            rawValue: "cancellation_target_not_found"
        )

        /// A request parameter or caller-supplied value was invalid.
        public static let invalidInput = Self(rawValue: "invalid_input")

        /// A pairing record was incomplete or malformed.
        public static let invalidPairingRecord = Self(
            rawValue: "invalid_pairing_record"
        )

        /// A host-local file operation failed.
        public static let fileSystem = Self(rawValue: "file_system")

        /// A socket, tunnel, or forwarding transport failed.
        public static let transport = Self(rawValue: "transport")

        /// The device or peer returned malformed protocol data.
        public static let protocolViolation = Self(
            rawValue: "protocol_violation"
        )

        /// RemoteXPC reset one HTTP/2 stream.
        public static let remoteXPCStreamReset = Self(
            rawValue: "remote_xpc_stream_reset"
        )

        /// Lockdown rejected an operation.
        public static let lockdown = Self(rawValue: "lockdown")

        /// The build does not include the required secure-session backend.
        public static let secureSessionUnsupported = Self(
            rawValue: "secure_session_unsupported"
        )

        /// Secure-session setup or encrypted I/O failed.
        public static let secureSession = Self(rawValue: "secure_session")

        /// The device rejected remote pairing.
        public static let remotePairing = Self(rawValue: "remote_pairing")

        /// AFC returned a nonzero status.
        public static let afcStatus = Self(rawValue: "afc_status")

        /// The heartbeat service failed or timed out.
        public static let heartbeat = Self(rawValue: "heartbeat")

        /// InstallationProxy rejected an operation.
        public static let installationProxy = Self(
            rawValue: "installation_proxy"
        )

        /// MISAgent returned a nonzero status.
        public static let misagentStatus = Self(rawValue: "misagent_status")

        /// Lockdown pairing requires user action or was rejected.
        public static let pairing = Self(rawValue: "pairing")

        /// An unclassified implementation failure escaped a handler.
        public static let internalFailure = Self(rawValue: "internal")
    }
}

/// Structured fields that accompany failures whose code alone loses context.
struct TunnelAgentErrorDetails: Encodable, Sendable {
    /// Protocol version rejected by the agent.
    let requestedVersion: Int?

    /// Protocol versions the supervisor may retry with.
    let supportedProtocolVersions: [Int]?

    /// Operation name that could not be dispatched.
    let operation: String?

    /// Active request the supervisor attempted to cancel.
    let targetID: String?

    /// RemoteXPC stream that reset before the operation completed.
    let streamIdentifier: UInt32?

    /// HTTP/2 error code reported for a RemoteXPC stream reset.
    let protocolErrorCode: UInt32?

    /// AFC status returned by the device.
    let afcStatus: UInt64?

    /// MISAgent status returned by the device.
    let misagentStatus: Int?

    /// Stable reason that refines the top-level error code.
    let reason: String?

    /// Whether cancellation left the operation's side effects uncertain.
    let operationMayHaveCompleted: Bool?

    /// Failure reported by an operation after cancellation had already won.
    let operationErrorCode: TunnelAgentProtocol.ErrorCode?

    /// Readable form of the failure reported after cancellation had won.
    let operationError: String?

    /// Keeps Swift acronym spelling while preserving the lower-camel wire key.
    private enum CodingKeys: String, CodingKey {
        case requestedVersion
        case supportedProtocolVersions
        case operation
        case targetID = "targetId"
        case streamIdentifier
        case protocolErrorCode
        case afcStatus
        case misagentStatus
        case reason
        case operationMayHaveCompleted
        case operationErrorCode
        case operationError
    }

    /// Creates structured details with only the context available for a failure.
    ///
    /// - Parameters:
    ///   - requestedVersion: Protocol version rejected by the agent.
    ///   - supportedProtocolVersions: Protocol versions accepted by the agent.
    ///   - operation: Operation name that could not be dispatched.
    ///   - targetID: Active request the supervisor attempted to cancel.
    ///   - streamIdentifier: RemoteXPC stream that reset.
    ///   - protocolErrorCode: HTTP/2 code reported for the stream reset.
    ///   - afcStatus: AFC status returned by the device.
    ///   - misagentStatus: MISAgent status returned by the device.
    ///   - reason: Stable reason that refines the top-level error code.
    ///   - operationMayHaveCompleted: Whether side effects remain uncertain.
    ///   - operationErrorCode: Failure reported after cancellation had won.
    ///   - operationError: Readable form of the concurrent operation failure.
    init(
        requestedVersion: Int? = nil,
        supportedProtocolVersions: [Int]? = nil,
        operation: String? = nil,
        targetID: String? = nil,
        streamIdentifier: UInt32? = nil,
        protocolErrorCode: UInt32? = nil,
        afcStatus: UInt64? = nil,
        misagentStatus: Int? = nil,
        reason: String? = nil,
        operationMayHaveCompleted: Bool? = nil,
        operationErrorCode: TunnelAgentProtocol.ErrorCode? = nil,
        operationError: String? = nil
    ) {
        self.requestedVersion = requestedVersion
        self.supportedProtocolVersions = supportedProtocolVersions
        self.operation = operation
        self.targetID = targetID
        self.streamIdentifier = streamIdentifier
        self.protocolErrorCode = protocolErrorCode
        self.afcStatus = afcStatus
        self.misagentStatus = misagentStatus
        self.reason = reason
        self.operationMayHaveCompleted = operationMayHaveCompleted
        self.operationErrorCode = operationErrorCode
        self.operationError = operationError
    }
}

/// One normalized wire failure before it is encoded into a reply.
struct TunnelAgentFailure: Error, Sendable {
    /// Stable identifier used by supervisors for control flow.
    let code: TunnelAgentProtocol.ErrorCode

    /// Readable error text retained for operators and legacy supervisors.
    let message: String

    /// Structured context needed to interpret the failure safely.
    let details: TunnelAgentErrorDetails?

    /// Creates a failure that preserves both machine and human context.
    ///
    /// - Parameters:
    ///   - code: Stable identifier used by supervisors for control flow.
    ///   - message: Readable error text for operators and legacy supervisors.
    ///   - details: Structured context needed to interpret the failure safely.
    init(
        code: TunnelAgentProtocol.ErrorCode,
        message: String,
        details: TunnelAgentErrorDetails? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// Converts library and protocol failures into the stable wire taxonomy.
    ///
    /// Known failures retain their actionable values. Unknown failures use the
    /// `internal` wire code and preserve their runtime description for
    /// diagnostics without exposing Swift case names as protocol identifiers.
    ///
    /// - Parameter error: Failure raised by an operation handler.
    /// - Returns: A failure safe to encode into a protocol reply.
    static func normalize(_ error: any Error) -> TunnelAgentFailure {
        if let failure = error as? TunnelAgentFailure {
            return failure
        }
        if error is CancellationError {
            return cancelled(operationMayHaveCompleted: false)
        }
        if let pairingError = error as? LockdownPairingError {
            return TunnelAgentFailure(
                code: .pairing,
                message: String(describing: pairingError),
                details: TunnelAgentErrorDetails(
                    reason: pairingReason(pairingError)
                )
            )
        }
        guard let deviceError = error as? RorkDeviceError else {
            return TunnelAgentFailure(
                code: .internalFailure,
                message: String(describing: error)
            )
        }

        let message = String(describing: deviceError)
        switch deviceError {
        case .invalidInput:
            return TunnelAgentFailure(code: .invalidInput, message: message)
        case .cancelled:
            return cancelled(operationMayHaveCompleted: false)
        case .invalidPairingRecord:
            return TunnelAgentFailure(code: .invalidPairingRecord, message: message)
        case let .pairing(pairingError):
            return TunnelAgentFailure(
                code: .pairing,
                message: message,
                details: TunnelAgentErrorDetails(
                    reason: pairingReason(pairingError)
                )
            )
        case .fileSystem:
            return TunnelAgentFailure(code: .fileSystem, message: message)
        case .transport:
            return TunnelAgentFailure(code: .transport, message: message)
        case .protocolViolation:
            return TunnelAgentFailure(code: .protocolViolation, message: message)
        case let .remoteXPCStreamReset(streamIdentifier, errorCode):
            return TunnelAgentFailure(
                code: .remoteXPCStreamReset,
                message: message,
                details: TunnelAgentErrorDetails(
                    streamIdentifier: streamIdentifier,
                    protocolErrorCode: errorCode
                )
            )
        case .lockdown:
            return TunnelAgentFailure(code: .lockdown, message: message)
        case .secureSessionUnsupported:
            return TunnelAgentFailure(
                code: .secureSessionUnsupported,
                message: message
            )
        case .secureSession:
            return TunnelAgentFailure(code: .secureSession, message: message)
        case let .remotePairing(rejection):
            return TunnelAgentFailure(
                code: .remotePairing,
                message: message,
                details: TunnelAgentErrorDetails(
                    reason: remotePairingReason(rejection)
                )
            )
        case let .afcStatus(status):
            return TunnelAgentFailure(
                code: .afcStatus,
                message: message,
                details: TunnelAgentErrorDetails(afcStatus: status)
            )
        case .heartbeat:
            return TunnelAgentFailure(code: .heartbeat, message: message)
        case let .installationProxy(installationError):
            return TunnelAgentFailure(
                code: .installationProxy,
                message: message,
                details: TunnelAgentErrorDetails(
                    reason: installationError.code.rawValue
                )
            )
        case let .misagentStatus(status):
            return TunnelAgentFailure(
                code: .misagentStatus,
                message: message,
                details: TunnelAgentErrorDetails(misagentStatus: status)
            )
        }
    }

    /// Creates a cancellation failure with explicit side-effect uncertainty.
    ///
    /// - Parameters:
    ///   - operationMayHaveCompleted: Whether callers must reconcile side effects.
    ///   - operationErrorCode: Failure reported after cancellation had won.
    ///   - operationError: Readable form of the concurrent operation failure.
    /// - Returns: A stable cancellation failure for the supervisor.
    static func cancelled(
        operationMayHaveCompleted: Bool,
        operationErrorCode: TunnelAgentProtocol.ErrorCode? = nil,
        operationError: String? = nil
    ) -> TunnelAgentFailure {
        TunnelAgentFailure(
            code: .cancelled,
            message: "The request was cancelled.",
            details: TunnelAgentErrorDetails(
                operationMayHaveCompleted: operationMayHaveCompleted,
                operationErrorCode: operationErrorCode,
                operationError: operationError
            )
        )
    }
}

/// Returns a stable pairing reason without exposing Swift case spelling.
private func pairingReason(_ error: LockdownPairingError) -> String {
    switch error {
    case .userConfirmationRequired:
        return "user_confirmation_required"
    case .userDenied:
        return "user_denied"
    case .deviceLocked:
        return "device_locked"
    case .prohibited:
        return "prohibited"
    case .timedOut:
        return "timed_out"
    case .rejected:
        return "rejected"
    }
}

/// Returns a stable remote-pairing reason without exposing associated values.
private func remotePairingReason(_ rejection: RemotePairingRejection) -> String {
    switch rejection {
    case .unknown:
        return "unknown"
    case .authentication:
        return "authentication"
    case .backoff:
        return "backoff"
    case .maximumAttempts:
        return "maximum_attempts"
    case .maximumPeers:
        return "maximum_peers"
    case .unknownPeer:
        return "unknown_peer"
    case .unrecognized:
        return "unrecognized"
    }
}
