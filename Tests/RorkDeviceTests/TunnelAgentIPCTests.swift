import Foundation
import XCTest

@testable import RorkDevice

/// Decoding of one stdin request line into a dispatchable request.
final class TunnelAgentRequestDecodingTests: XCTestCase {
    func testDecodesIdOperationAndRetainsTheRawBody() throws {
        let line = #"{"id":"7","op":"apps-list","type":"all"}"#

        let outcome = TunnelAgentIPC.decodeRequest(from: line)

        guard case .request(let request) = outcome else {
            return XCTFail("Expected a decoded request, got \(outcome)")
        }
        XCTAssertEqual(request.id, "7")
        XCTAssertEqual(request.operation, "apps-list")
        // Handlers decode operation-specific fields from the retained line.
        XCTAssertTrue(String(data: request.line, encoding: .utf8)!.contains(#""type":"all""#))
    }

    func testRejectsALineThatIsNotJSON() {
        let outcome = TunnelAgentIPC.decodeRequest(from: "not json")

        guard case .malformed(_, let id) = outcome else {
            return XCTFail("Expected malformed, got \(outcome)")
        }
        XCTAssertNil(id)
    }

    func testRejectsARequestWithoutAnOperationButKeepsItsId() {
        let outcome = TunnelAgentIPC.decodeRequest(from: #"{"id":"9"}"#)

        guard case .malformed(_, let id) = outcome else {
            return XCTFail("Expected malformed, got \(outcome)")
        }
        XCTAssertEqual(id, "9")
    }

    func testDecodesTypedParametersFromTheRequestLine() throws {
        struct ListParameters: Decodable, Equatable {
            let type: String
        }
        let outcome = TunnelAgentIPC.decodeRequest(
            from: #"{"id":"7","op":"apps-list","type":"all"}"#
        )
        guard case .request(let request) = outcome else {
            return XCTFail("Expected a decoded request, got \(outcome)")
        }

        let parameters: ListParameters = try request.parameters()

        XCTAssertEqual(parameters, ListParameters(type: "all"))
    }

    func testTypedParameterDecodingFailuresNameTheOperation() {
        let outcome = TunnelAgentIPC.decodeRequest(from: #"{"id":"8","op":"apps-list"}"#)
        guard case .request(let request) = outcome else {
            return XCTFail("Expected a decoded request, got \(outcome)")
        }

        struct ListParameters: Decodable {
            let type: String
        }
        XCTAssertThrowsError(try request.parameters() as ListParameters) { error in
            XCTAssertTrue(String(describing: error).contains("apps-list"))
        }
    }

    func testRejectsARequestWithoutAnId() {
        let outcome = TunnelAgentIPC.decodeRequest(from: #"{"op":"ping"}"#)

        guard case .malformed(_, let id) = outcome else {
            return XCTFail("Expected malformed, got \(outcome)")
        }
        XCTAssertNil(id)
    }
}

/// Drives the serve loop through scripted stdin sessions. These cover
/// dispatch, error replies, and the end-of-file shutdown contract that
/// replaces the plain liveness watch.
final class TunnelAgentServeLoopTests: XCTestCase {
    func testAnswersAPingAndEndsWhenStdinCloses() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: TunnelAgentIPC.builtInHandlers(capabilities: ["ping", "capabilities"]),
                send: replies.record
            )
            return true
        }
        try stdin.fileHandleForWriting.write(contentsOf: Data(#"{"id":"1","op":"ping"}"#.utf8 + [0x0a]))
        let reply = try await replies.waitForReply(id: "1")
        try stdin.fileHandleForWriting.close()

        let ended = await serving.value
        XCTAssertTrue(ended)
        XCTAssertEqual(reply["event"] as? String, "op-result")
        XCTAssertEqual(reply["ok"] as? Bool, true)
    }

    func testListsCapabilities() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: TunnelAgentIPC.builtInHandlers(capabilities: ["ping", "capabilities"]),
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"2","op":"capabilities"}"#.utf8 + [0x0a])
        )

        let reply = try await replies.waitForReply(id: "2")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["capabilities"] as? [String], ["ping", "capabilities"])
        try stdin.fileHandleForWriting.close()
    }

    func testAnswersUnknownOperationsWithoutEndingTheLoop() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: TunnelAgentIPC.builtInHandlers(capabilities: ["ping"]),
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"3","op":"frobnicate"}"#.utf8 + [0x0a])
        )
        let unknown = try await replies.waitForReply(id: "3")
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertTrue((unknown["error"] as? String ?? "").contains("frobnicate"))

        // The loop keeps serving after an unknown operation.
        try stdin.fileHandleForWriting.write(contentsOf: Data(#"{"id":"4","op":"ping"}"#.utf8 + [0x0a]))
        let pong = try await replies.waitForReply(id: "4")
        XCTAssertEqual(pong["ok"] as? Bool, true)
        try stdin.fileHandleForWriting.close()
    }

    func testAnswersMalformedLinesWithAnErrorEventAndKeepsServing() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: TunnelAgentIPC.builtInHandlers(capabilities: ["ping"]),
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(contentsOf: Data("not json\n".utf8))
        let error = try await replies.waitForEvent("op-error")
        XCTAssertNil(error["id"])

        try stdin.fileHandleForWriting.write(contentsOf: Data(#"{"id":"5","op":"ping"}"#.utf8 + [0x0a]))
        let pong = try await replies.waitForReply(id: "5")
        XCTAssertEqual(pong["ok"] as? Bool, true)
        try stdin.fileHandleForWriting.close()
    }

    func testSplitsRequestsAcrossChunkBoundaries() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: TunnelAgentIPC.builtInHandlers(capabilities: ["ping"]),
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        // One request delivered in two writes, and two requests in one write.
        try stdin.fileHandleForWriting.write(contentsOf: Data(#"{"id":"6","op"#.utf8))
        try stdin.fileHandleForWriting.write(contentsOf: Data(#"":"ping"}"#.utf8 + [0x0a]))
        _ = try await replies.waitForReply(id: "6")
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"7","op":"ping"}"#.utf8 + [0x0a] + #"{"id":"8","op":"ping"}"#.utf8 + [0x0a])
        )
        _ = try await replies.waitForReply(id: "7")
        _ = try await replies.waitForReply(id: "8")
        try stdin.fileHandleForWriting.close()
    }
}

/// Collects NDJSON reply lines and answers queries about them.
private final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func record(_ line: Data) {
        lock.withLock {
            lines.append(line)
        }
    }

    private func decoded() -> [[String: Any]] {
        lock.withLock {
            lines.compactMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
        }
    }

    func waitForReply(id: String) async throws -> [String: Any] {
        for _ in 0..<400 {
            if let reply = decoded().first(where: { $0["id"] as? String == id }) {
                return reply
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RorkDeviceError.transport("No reply for request \(id).")
    }

    func waitForEvent(_ event: String) async throws -> [String: Any] {
        for _ in 0..<400 {
            if let reply = decoded().first(where: { $0["event"] as? String == event }) {
                return reply
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RorkDeviceError.transport("No \(event) event.")
    }
}
