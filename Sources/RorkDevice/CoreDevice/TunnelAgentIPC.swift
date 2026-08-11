import Foundation

/// Serves newline-delimited JSON requests on a tunnel agent's standard input.
///
/// A supervising process writes one request object per line and reads replies
/// from the agent's standard output, matching them up by the request `id`.
/// The read loop is also the parent-liveness signal. When standard input
/// reaches end-of-file the supervisor is gone, the loop returns, and the
/// caller shuts the agent down. Handlers own what each operation means.
/// This type owns framing, dispatch, and reply ordering.
public enum TunnelAgentIPC {
    /// One decoded request line, ready for dispatch.
    public struct Request: Equatable, Sendable {
        /// Supervisor-chosen correlation value repeated in every reply.
        public let id: String

        /// Operation name used to select a handler.
        public let operation: String

        /// Protocol version requested by the supervisor, or nil for legacy
        /// clients that use version one implicitly.
        public let protocolVersion: Int?

        /// The complete request line, retained so handlers can decode
        /// operation-specific fields with their own `Decodable` types
        /// through ``parameters()``.
        public let line: Data

        /// Decodes the operation's parameters from the request line.
        ///
        /// The parameter type lives with its handler, so each operation's
        /// contract stays local to the code that implements it. A decoding
        /// failure names the operation, which becomes the `ok: false` reply
        /// the supervisor sees.
        public func parameters<Parameters: Decodable>(
            _ type: Parameters.Type = Parameters.self
        ) throws -> Parameters {
            do {
                return try JSONDecoder().decode(type, from: line)
            } catch {
                throw RorkDeviceError.invalidInput(
                    "Invalid parameters for \(operation): \(describeDeviceSessionError(error))"
                )
            }
        }
    }

    /// The result of decoding one input line.
    public enum DecodeOutcome: Equatable, Sendable {
        /// The line carried a dispatchable request.
        case request(Request)

        /// The line was not a usable request. The id is present when it
        /// could still be extracted, so the error reply stays correlatable.
        case malformed(reason: String, id: String?)
    }

    /// Produces the reply payload for one request.
    ///
    /// The payload's fields are merged into the top level of the `op-result`
    /// reply. Return nil when the result carries no fields beyond the
    /// envelope. The dispatcher owns the `id`, `event`, and `ok` fields.
    /// Throwing produces an `ok: false` result carrying the error's
    /// description.
    public typealias Handler = @Sendable (Request) async throws -> (any Encodable & Sendable)?

    /// The wire shape of a request envelope.
    private struct RequestEnvelope: Decodable {
        let id: String
        let op: String
        let protocolVersion: Int?
    }

    /// Salvages a correlation id from a line that failed envelope decoding.
    private struct RequestIdProbe: Decodable {
        let id: String?
    }

    /// The payload for the `capabilities` operation.
    private struct CapabilitiesPayload: Encodable {
        let capabilities: [String]
        let protocolVersion = TunnelAgentProtocol.currentVersion
        let supportedProtocolVersions = TunnelAgentProtocol.supportedVersions
        let agentVersion = RorkDevice.version
    }

    /// Operations implemented by the protocol layer rather than a device handler.
    public static let builtInOperationNames = [
        "ping",
        "capabilities",
        "cancel",
    ]

    /// Decodes one input line into a request or a correlatable failure.
    public static func decodeRequest(from line: String) -> DecodeOutcome {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(RequestEnvelope.self, from: data),
           !envelope.id.isEmpty, !envelope.op.isEmpty {
            return .request(
                Request(
                    id: envelope.id,
                    operation: envelope.op,
                    protocolVersion: envelope.protocolVersion,
                    line: data
                )
            )
        }
        guard let probe = try? decoder.decode(RequestIdProbe.self, from: data) else {
            return .malformed(reason: "The request line is not a JSON object.", id: nil)
        }
        guard let id = probe.id, !id.isEmpty else {
            return .malformed(reason: "The request has no string id.", id: nil)
        }
        return .malformed(reason: "The request has no op field.", id: id)
    }

    /// The operations every serving agent supports before any device work.
    ///
    /// `ping` proves the channel works. `capabilities` reports the operations
    /// the supervisor may route through the pipe.
    public static func builtInHandlers(capabilities: [String]) -> [String: Handler] {
        [
            "ping": { _ in nil },
            "capabilities": { _ in CapabilitiesPayload(capabilities: capabilities) },
        ]
    }

    /// Reads requests until end-of-file, dispatching each one to a handler.
    ///
    /// Every request runs as its own task, so a slow operation never blocks
    /// the read loop or other operations. Replies are serialized through
    /// `send`, one complete line per call. The method returns when the input
    /// reaches end-of-file, which means the supervisor is gone.
    public static func serve(
        requestsFrom input: FileHandle,
        handlers: [String: Handler],
        send: @escaping @Sendable (Data) -> Void
    ) async {
        let writer = ReplyWriter(send: send)
        let inFlightRequests = InFlightRequestRegistry(writer: writer)
        var pending = Data()
        for await chunk in chunks(of: input) {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let lineData = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }
                await dispatch(
                    line: line,
                    handlers: handlers,
                    writer: writer,
                    inFlightRequests: inFlightRequests
                )
            }
        }
        let cancelledTasks = await inFlightRequests.cancelAll()
        for task in cancelledTasks {
            await task.value
        }
    }

    /// Routes one decoded line to its handler task or to an error reply.
    private static func dispatch(
        line: String,
        handlers: [String: Handler],
        writer: ReplyWriter,
        inFlightRequests: InFlightRequestRegistry
    ) async {
        switch decodeRequest(from: line) {
        case .malformed(let reason, let id):
            writer.write(
                Reply.failure(
                    event: "op-error",
                    id: id,
                    failure: TunnelAgentFailure(
                        code: .malformedRequest,
                        message: reason
                    )
                )
            )
        case .request(let request):
            if await inFlightRequests.contains(request.id) {
                writer.write(
                    Reply.failure(
                        event: "op-error",
                        id: request.id,
                        failure: duplicateRequestFailure(id: request.id)
                    )
                )
                return
            }
            if let version = request.protocolVersion,
               !TunnelAgentProtocol.supportedVersions.contains(version) {
                writer.write(
                    Reply.failure(
                        id: request.id,
                        failure: TunnelAgentFailure(
                            code: .unsupportedProtocolVersion,
                            message: "Unsupported tunnel agent protocol version \(version).",
                            details: TunnelAgentErrorDetails(
                                requestedVersion: version,
                                supportedVersions: TunnelAgentProtocol.supportedVersions
                            )
                        )
                    )
                )
                return
            }
            if request.operation == "cancel" {
                let started = await inFlightRequests.start(id: request.id) {
                    await cancellationReply(
                        request: request,
                        inFlightRequests: inFlightRequests
                    )
                }
                if !started {
                    writer.write(
                        Reply.failure(
                            event: "op-error",
                            id: request.id,
                            failure: duplicateRequestFailure(id: request.id)
                        )
                    )
                }
                return
            }
            guard let handler = handlers[request.operation] else {
                writer.write(
                    Reply.failure(
                        id: request.id,
                        failure: TunnelAgentFailure(
                            code: .unknownOperation,
                            message: "Unknown operation \(request.operation).",
                            details: TunnelAgentErrorDetails(
                                operation: request.operation
                            )
                        )
                    )
                )
                return
            }

            let started = await inFlightRequests.start(id: request.id) {
                do {
                    let payload = try await handler(request)
                    return Reply.success(id: request.id, payload: payload)
                } catch {
                    return Reply.failure(
                        id: request.id,
                        failure: TunnelAgentFailure.normalize(error)
                    )
                }
            }
            if !started {
                writer.write(
                    Reply.failure(
                        event: "op-error",
                        id: request.id,
                        failure: duplicateRequestFailure(id: request.id)
                    )
                )
            }
        }
    }

    /// Builds the reply for cancelling one supervisor-selected request.
    private static func cancellationReply(
        request: Request,
        inFlightRequests: InFlightRequestRegistry
    ) async -> Reply {
        let parameters: CancelParameters
        do {
            parameters = try request.parameters()
        } catch {
            return Reply.failure(
                id: request.id,
                failure: TunnelAgentFailure.normalize(error)
            )
        }
        guard parameters.targetId != request.id else {
            return Reply.failure(
                id: request.id,
                failure: TunnelAgentFailure(
                    code: .invalidInput,
                    message: "A cancel request cannot target its own id."
                )
            )
        }

        guard await inFlightRequests.cancel(parameters.targetId) else {
            return Reply.failure(
                id: request.id,
                failure: TunnelAgentFailure(
                    code: .cancellationTargetNotFound,
                    message: "No in-flight request has id \(parameters.targetId).",
                    details: TunnelAgentErrorDetails(
                        targetID: parameters.targetId
                    )
                )
            )
        }
        return Reply.success(id: request.id, payload: nil)
    }

    /// Describes a request id that is already owned by an active operation.
    private static func duplicateRequestFailure(id: String) -> TunnelAgentFailure {
        TunnelAgentFailure(
            code: .duplicateRequestID,
            message: "Request id \(id) is already in flight."
        )
    }

    /// Streams the file handle's bytes as they arrive, ending at end-of-file.
    private static func chunks(of input: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            input.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
            continuation.onTermination = { _ in
                input.readabilityHandler = nil
            }
        }
    }

    /// Parameters accepted by the protocol-level cancel operation.
    private struct CancelParameters: Decodable {
        let targetId: String
    }
}

/// One reply line, carrying the shared envelope and the operation payload.
///
/// The payload encodes into the same keyed container as the envelope, so its
/// fields appear at the top level of the reply object rather than nested.
/// The type stays private because it describes the wire format the dispatcher
/// owns. Handlers hand back payloads and supervisors read JSON, so no caller
/// has a reason to construct or inspect a `Reply` directly.
private struct Reply: Encodable, Sendable {
    /// Reply kind, `op-result` for handled requests and `op-error` for lines
    /// that could not be dispatched.
    let event: String

    /// The request's correlation id, absent when the line had none to salvage.
    let id: String?

    /// Whether the operation succeeded, absent on `op-error` lines.
    let ok: Bool?

    /// Human-readable failure description, absent on success.
    let error: String?

    /// Stable machine-readable failure identifier, absent on success.
    let errorCode: TunnelAgentProtocol.ErrorCode?

    /// Structured context for failures whose code needs additional values.
    let errorDetails: TunnelAgentErrorDetails?

    /// Operation-specific fields flattened into the reply, or nil when the
    /// envelope says everything.
    let payload: (any Encodable & Sendable)?

    /// The payload has no key on purpose. It encodes through the same encoder
    /// so its fields merge into this object instead of nesting.
    private enum CodingKeys: String, CodingKey {
        case event
        case id
        case ok
        case error
        case errorCode
        case errorDetails
    }

    /// Creates a successful handled-operation reply.
    static func success(
        id: String,
        payload: (any Encodable & Sendable)?
    ) -> Reply {
        Reply(
            event: "op-result",
            id: id,
            ok: true,
            error: nil,
            errorCode: nil,
            errorDetails: nil,
            payload: payload
        )
    }

    /// Creates an unsuccessful reply while preserving the legacy error text.
    static func failure(
        event: String = "op-result",
        id: String?,
        failure: TunnelAgentFailure
    ) -> Reply {
        Reply(
            event: event,
            id: id,
            ok: event == "op-result" ? false : nil,
            error: failure.message,
            errorCode: failure.code,
            errorDetails: failure.details,
            payload: nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(errorDetails, forKey: .errorDetails)
        try payload?.encode(to: encoder)
    }
}

/// Serializes reply lines so concurrent handlers cannot interleave output.
private final class ReplyWriter: @unchecked Sendable {
    private let lock = NSLock()

    /// Receives one encoded reply line per call, never a partial line.
    private let send: @Sendable (Data) -> Void

    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    /// Encodes the reply and forwards it while holding the ordering lock.
    ///
    /// A reply that fails to encode is dropped rather than crashing the
    /// serving loop. The dispatcher builds replies from strings, booleans,
    /// and handler payloads that already encoded themselves once, so this is
    /// a defensive guard rather than an expected path.
    func write(_ reply: Reply) {
        guard let data = try? JSONEncoder().encode(reply) else {
            return
        }
        lock.withLock {
            send(data)
        }
    }
}

/// Owns cancellable request tasks and arbitrates their terminal replies.
private actor InFlightRequestRegistry {
    /// One task and whether a supervisor cancellation won its completion race.
    private struct Entry {
        var task: Task<Void, Never>?
        var cancellationRequested: Bool
    }

    private var entries: [String: Entry] = [:]
    private let writer: ReplyWriter

    init(writer: ReplyWriter) {
        self.writer = writer
    }

    /// Returns whether an active request already owns this identifier.
    func contains(_ id: String) -> Bool {
        entries[id] != nil
    }

    /// Starts one request after atomically reserving its identifier.
    func start(
        id: String,
        operation: @escaping @Sendable () async -> Reply
    ) -> Bool {
        guard entries[id] == nil else {
            return false
        }

        // The identifier is reserved first so a fast task always finds an entry.
        entries[id] = Entry(
            task: nil,
            cancellationRequested: false
        )
        let task = Task { [weak self] in
            let reply = await operation()
            await self?.finish(id: id, proposedReply: reply)
        }
        guard var entry = entries[id] else {
            task.cancel()
            return true
        }
        entry.task = task
        entries[id] = entry
        if entry.cancellationRequested {
            task.cancel()
        }
        return true
    }

    /// Requests cancellation and returns false when the target already ended.
    func cancel(_ id: String) -> Bool {
        guard var entry = entries[id] else {
            return false
        }
        entry.cancellationRequested = true
        entries[id] = entry
        entry.task?.cancel()
        return true
    }

    /// Cancels every remaining task and returns them for orderly joining.
    func cancelAll() -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for id in Array(entries.keys) {
            guard var entry = entries[id] else {
                continue
            }
            entry.cancellationRequested = true
            entries[id] = entry
            entry.task?.cancel()
            if let task = entry.task {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// Emits one terminal reply, giving a requested cancellation precedence.
    private func finish(
        id: String,
        proposedReply: Reply
    ) {
        guard let entry = entries.removeValue(forKey: id) else {
            return
        }
        if entry.cancellationRequested {
            writer.write(
                Reply.failure(
                    id: id,
                    failure: TunnelAgentFailure(
                        code: .cancelled,
                        message: "The request was cancelled."
                    )
                )
            )
        } else {
            writer.write(proposedReply)
        }
    }
}
