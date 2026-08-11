import Foundation

/// Stable metadata and error identifiers for the tunnel agent's NDJSON protocol.
public enum TunnelAgentProtocol {
    /// Protocol version implemented by this agent.
    public static let currentVersion = 1

    /// Protocol versions this agent can negotiate with a supervisor.
    public static let supportedVersions = [currentVersion]

    /// Stable failure identifiers carried by unsuccessful agent replies.
    public enum ErrorCode: String, Codable, Sendable {
        /// The input line could not be decoded as a request envelope.
        case malformedRequest = "malformed_request"

        /// The supervisor requested a protocol version the agent cannot serve.
        case unsupportedProtocolVersion = "unsupported_protocol_version"

        /// Another active operation already owns the request identifier.
        case duplicateRequestID = "duplicate_request_id"

        /// No registered operation matches the requested name.
        case unknownOperation = "unknown_operation"

        /// The supervisor or agent shutdown cancelled the operation.
        case cancelled

        /// No active operation matches the requested cancellation target.
        case cancellationTargetNotFound = "cancellation_target_not_found"

        /// A request parameter or caller-supplied value was invalid.
        case invalidInput = "invalid_input"

        /// A pairing record was incomplete or malformed.
        case invalidPairingRecord = "invalid_pairing_record"

        /// A socket, tunnel, or forwarding transport failed.
        case transport

        /// The device or peer returned malformed protocol data.
        case protocolViolation = "protocol_violation"

        /// RemoteXPC reset one HTTP/2 stream.
        case remoteXPCStreamReset = "remote_xpc_stream_reset"

        /// Lockdown rejected an operation.
        case lockdown

        /// The build does not include the required secure-session backend.
        case secureSessionUnsupported = "secure_session_unsupported"

        /// Secure-session setup or encrypted I/O failed.
        case secureSession = "secure_session"

        /// The device rejected remote pairing.
        case remotePairing = "remote_pairing"

        /// AFC returned a nonzero status.
        case afcStatus = "afc_status"

        /// The heartbeat service failed or timed out.
        case heartbeat

        /// InstallationProxy rejected an operation.
        case installationProxy = "installation_proxy"

        /// MISAgent returned a nonzero status.
        case misagentStatus = "misagent_status"

        /// Lockdown pairing requires user action or was rejected.
        case pairing

        /// An unclassified implementation failure escaped a handler.
        case internalFailure = "internal"
    }
}

/// Structured fields that accompany failures whose code alone loses context.
struct TunnelAgentErrorDetails: Encodable, Sendable {
    let requestedVersion: Int?
    let supportedVersions: [Int]?
    let operation: String?
    let targetID: String?
    let streamIdentifier: UInt32?
    let protocolErrorCode: UInt32?
    let afcStatus: UInt64?
    let misagentStatus: Int?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case requestedVersion
        case supportedVersions
        case operation
        case targetID = "targetId"
        case streamIdentifier
        case protocolErrorCode
        case afcStatus
        case misagentStatus
        case reason
    }

    init(
        requestedVersion: Int? = nil,
        supportedVersions: [Int]? = nil,
        operation: String? = nil,
        targetID: String? = nil,
        streamIdentifier: UInt32? = nil,
        protocolErrorCode: UInt32? = nil,
        afcStatus: UInt64? = nil,
        misagentStatus: Int? = nil,
        reason: String? = nil
    ) {
        self.requestedVersion = requestedVersion
        self.supportedVersions = supportedVersions
        self.operation = operation
        self.targetID = targetID
        self.streamIdentifier = streamIdentifier
        self.protocolErrorCode = protocolErrorCode
        self.afcStatus = afcStatus
        self.misagentStatus = misagentStatus
        self.reason = reason
    }
}

/// One normalized wire failure before it is encoded into a reply.
struct TunnelAgentFailure: Error, Sendable {
    let code: TunnelAgentProtocol.ErrorCode
    let message: String
    let details: TunnelAgentErrorDetails?

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
    static func normalize(_ error: any Error) -> TunnelAgentFailure {
        if let failure = error as? TunnelAgentFailure {
            return failure
        }
        if error is CancellationError {
            return TunnelAgentFailure(
                code: .cancelled,
                message: "The request was cancelled."
            )
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
        case .invalidPairingRecord:
            return TunnelAgentFailure(code: .invalidPairingRecord, message: message)
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
