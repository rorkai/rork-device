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

        /// The complete request line, retained so handlers can decode
        /// operation-specific fields with their own `Decodable` types.
        public let line: Data
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
    }

    /// Salvages a correlation id from a line that failed envelope decoding.
    private struct RequestIdProbe: Decodable {
        let id: String?
    }

    /// The payload for the `capabilities` operation.
    private struct CapabilitiesPayload: Encodable {
        let capabilities: [String]
    }

    /// Decodes one input line into a request or a correlatable failure.
    public static func decodeRequest(from line: String) -> DecodeOutcome {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(RequestEnvelope.self, from: data),
           !envelope.id.isEmpty, !envelope.op.isEmpty {
            return .request(
                Request(id: envelope.id, operation: envelope.op, line: data)
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
        await withTaskGroup(of: Void.self) { group in
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
                    dispatch(line: line, handlers: handlers, writer: writer, group: &group)
                }
            }
            group.cancelAll()
        }
    }

    /// Routes one decoded line to its handler task or to an error reply.
    private static func dispatch(
        line: String,
        handlers: [String: Handler],
        writer: ReplyWriter,
        group: inout TaskGroup<Void>
    ) {
        switch decodeRequest(from: line) {
        case .malformed(let reason, let id):
            writer.write(Reply(event: "op-error", id: id, ok: nil, error: reason, payload: nil))
        case .request(let request):
            guard let handler = handlers[request.operation] else {
                writer.write(
                    Reply(
                        event: "op-result",
                        id: request.id,
                        ok: false,
                        error: "Unknown operation \(request.operation).",
                        payload: nil
                    )
                )
                return
            }
            group.addTask {
                do {
                    let payload = try await handler(request)
                    writer.write(
                        Reply(event: "op-result", id: request.id, ok: true, error: nil, payload: payload)
                    )
                } catch {
                    writer.write(
                        Reply(
                            event: "op-result",
                            id: request.id,
                            ok: false,
                            error: String(describing: error),
                            payload: nil
                        )
                    )
                }
            }
        }
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
}

/// One reply line: the shared envelope plus a flattened operation payload.
///
/// The payload encodes into the same keyed container as the envelope, so its
/// fields appear at the top level of the reply object rather than nested.
private struct Reply: Encodable {
    let event: String
    let id: String?
    let ok: Bool?
    let error: String?
    let payload: (any Encodable & Sendable)?

    private enum CodingKeys: String, CodingKey {
        case event
        case id
        case ok
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
        try payload?.encode(to: encoder)
    }
}

/// Serializes reply lines so concurrent handlers cannot interleave output.
private final class ReplyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let send: @Sendable (Data) -> Void

    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    func write(_ reply: Reply) {
        guard let data = try? JSONEncoder().encode(reply) else {
            return
        }
        lock.withLock {
            send(data)
        }
    }
}
