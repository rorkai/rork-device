import Foundation

/// Serves newline-delimited JSON requests on a tunnel agent's standard input.
///
/// A supervising process writes one request object per line and reads replies
/// from the agent's standard output, correlated by the request `id`. The read
/// loop doubles as the parent-liveness signal: end-of-file on standard input
/// means the supervisor is gone, so the loop returns and the caller shuts the
/// agent down. Handlers own operation semantics; this type owns framing,
/// dispatch, and reply ordering.
public enum TunnelAgentIPC {
    /// One decoded request line, ready for dispatch.
    public struct Request: Equatable, Sendable {
        /// Supervisor-chosen correlation value repeated in every reply.
        public let id: String

        /// Operation name used to select a handler.
        public let operation: String

        /// The complete request line, retained so handlers can decode
        /// operation-specific fields with their own types.
        public let body: Data
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
    /// The returned dictionary is merged into the `op-result` envelope; the
    /// `id`, `event`, and `ok` fields are owned by the dispatcher. Throwing
    /// produces an `ok: false` result carrying the error's description.
    public typealias Handler = @Sendable (Request) async throws -> [String: Any]

    /// Decodes one input line into a request or a correlatable failure.
    public static func decodeRequest(from line: String) -> DecodeOutcome {
        let data = Data(line.utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed(reason: "The request line is not a JSON object.", id: nil)
        }
        let id = object["id"] as? String
        guard let id, !id.isEmpty else {
            return .malformed(reason: "The request has no string id.", id: nil)
        }
        guard let operation = object["op"] as? String, !operation.isEmpty else {
            return .malformed(reason: "The request has no op field.", id: id)
        }
        return .request(Request(id: id, operation: operation, body: data))
    }

    /// The operations every serving agent supports before any device work.
    ///
    /// `ping` proves the channel; `capabilities` reports the operations the
    /// supervisor may route through the pipe.
    public static func baseHandlers(capabilities: [String]) -> [String: Handler] {
        [
            "ping": { _ in [:] },
            "capabilities": { _ in ["capabilities": capabilities] },
        ]
    }

    /// Reads requests from `input` until end-of-file, dispatching each one.
    ///
    /// Every request runs as its own task, so a slow operation never blocks
    /// the read loop or other operations. Replies are serialized through
    /// `send`, one complete line per call. Returns when the input reaches
    /// end-of-file, which is the supervisor-is-gone signal.
    public static func serve(
        input: FileHandle,
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
            writer.write(envelope(event: "op-error", id: id, fields: ["error": reason]))
        case .request(let request):
            guard let handler = handlers[request.operation] else {
                writer.write(
                    envelope(
                        event: "op-result",
                        id: request.id,
                        fields: [
                            "ok": false,
                            "error": "Unknown operation \(request.operation).",
                        ]
                    )
                )
                return
            }
            group.addTask {
                do {
                    var fields = try await handler(request)
                    fields["ok"] = true
                    writer.write(envelope(event: "op-result", id: request.id, fields: fields))
                } catch {
                    writer.write(
                        envelope(
                            event: "op-result",
                            id: request.id,
                            fields: [
                                "ok": false,
                                "error": String(describing: error),
                            ]
                        )
                    )
                }
            }
        }
    }

    /// Builds one reply object with the shared envelope fields.
    private static func envelope(
        event: String,
        id: String?,
        fields: [String: Any]
    ) -> [String: Any] {
        var object = fields
        object["event"] = event
        if let id {
            object["id"] = id
        }
        return object
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

/// Serializes reply lines so concurrent handlers cannot interleave output.
private final class ReplyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let send: @Sendable (Data) -> Void

    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        lock.withLock {
            send(data)
        }
    }
}
