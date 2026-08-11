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
        XCTAssertNil(request.protocolVersion)
        // Handlers decode operation-specific fields from the retained line.
        XCTAssertTrue(String(data: request.line, encoding: .utf8)!.contains(#""type":"all""#))
    }

    func testDecodesAnOptionalProtocolVersion() {
        let line = #"{"id":"7","op":"apps-list","protocolVersion":1}"#

        let outcome = TunnelAgentIPC.decodeRequest(from: line)

        guard case .request(let request) = outcome else {
            return XCTFail("Expected a decoded request, got \(outcome)")
        }
        XCTAssertEqual(request.protocolVersion, 1)
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

/// Stable mappings from Swift failures to the tunnel agent's wire codes.
final class TunnelAgentFailureTests: XCTestCase {
    func testProtocolV1ErrorCodesRemainStable() {
        let cases: [(TunnelAgentProtocol.ErrorCode, String)] = [
            (.malformedRequest, "malformed_request"),
            (.unsupportedProtocolVersion, "unsupported_protocol_version"),
            (.duplicateRequestID, "duplicate_request_id"),
            (.unknownOperation, "unknown_operation"),
            (.cancelled, "cancelled"),
            (.cancellationTargetNotFound, "cancellation_target_not_found"),
            (.invalidInput, "invalid_input"),
            (.invalidPairingRecord, "invalid_pairing_record"),
            (.fileSystem, "file_system"),
            (.transport, "transport"),
            (.protocolViolation, "protocol_violation"),
            (.remoteXPCStreamReset, "remote_xpc_stream_reset"),
            (.lockdown, "lockdown"),
            (.secureSessionUnsupported, "secure_session_unsupported"),
            (.secureSession, "secure_session"),
            (.remotePairing, "remote_pairing"),
            (.afcStatus, "afc_status"),
            (.heartbeat, "heartbeat"),
            (.installationProxy, "installation_proxy"),
            (.misagentStatus, "misagent_status"),
            (.pairing, "pairing"),
            (.internalFailure, "internal"),
        ]

        for (code, rawValue) in cases {
            XCTAssertEqual(code.rawValue, rawValue)
        }
    }

    func testMapsEveryDeviceErrorCaseToAStableCode() {
        let cases: [(RorkDeviceError, TunnelAgentProtocol.ErrorCode)] = [
            (.invalidInput("input"), .invalidInput),
            (.cancelled, .cancelled),
            (.invalidPairingRecord("pairing"), .invalidPairingRecord),
            (.pairing(.deviceLocked), .pairing),
            (
                .fileSystem(path: "/tmp/file", reason: "missing"),
                .fileSystem
            ),
            (.transport("transport"), .transport),
            (.protocolViolation("protocol"), .protocolViolation),
            (
                .remoteXPCStreamReset(streamIdentifier: 3, errorCode: 8),
                .remoteXPCStreamReset
            ),
            (.lockdown("lockdown"), .lockdown),
            (.secureSessionUnsupported, .secureSessionUnsupported),
            (.secureSession("secure"), .secureSession),
            (.remotePairing(.unknownPeer), .remotePairing),
            (.afcStatus(4), .afcStatus),
            (.heartbeat("heartbeat"), .heartbeat),
            (
                .installationProxy(
                    InstallationError(
                        code: .applicationVerificationFailed
                    )
                ),
                .installationProxy
            ),
            (.misagentStatus(7), .misagentStatus),
        ]

        for (error, expectedCode) in cases {
            XCTAssertEqual(
                TunnelAgentFailure.normalize(error).code,
                expectedCode,
                "Unexpected wire code for \(error)"
            )
        }
    }

    func testMapsPairingAndCancellationWithoutSwiftCaseNames() {
        let pairing = TunnelAgentFailure.normalize(
            LockdownPairingError.userConfirmationRequired
        )
        XCTAssertEqual(pairing.code, .pairing)
        XCTAssertEqual(pairing.details?.reason, "user_confirmation_required")

        let cancellation = TunnelAgentFailure.normalize(CancellationError())
        XCTAssertEqual(cancellation.code, .cancelled)
        XCTAssertEqual(cancellation.message, "The request was cancelled.")
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
        XCTAssertEqual(reply["protocolVersion"] as? Int, 1)
        XCTAssertEqual(reply["supportedProtocolVersions"] as? [Int], [1])
        XCTAssertEqual(reply["agentVersion"] as? String, RorkDevice.version)
        try stdin.fileHandleForWriting.close()
    }

    func testRejectsAnUnsupportedProtocolVersion() async throws {
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
            contentsOf: Data(
                #"{"id":"version","op":"capabilities","protocolVersion":99}"#.utf8 + [0x0a]
            )
        )

        let reply = try await replies.waitForReply(id: "version")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["errorCode"] as? String, "unsupported_protocol_version")
        let details = try XCTUnwrap(reply["errorDetails"] as? [String: Any])
        XCTAssertEqual(details["requestedVersion"] as? Int, 99)
        XCTAssertEqual(details["supportedVersions"] as? [Int], [1])
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
        XCTAssertEqual(unknown["errorCode"] as? String, "unknown_operation")

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
        XCTAssertEqual(error["errorCode"] as? String, "malformed_request")

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

    func testMapsDeviceErrorsToStableCodesAndDetails() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()
        let handlers: [String: TunnelAgentIPC.Handler] = [
            "reset": { _ in
                throw RorkDeviceError.remoteXPCStreamReset(
                    streamIdentifier: 3,
                    errorCode: 8
                )
            },
        ]

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: handlers,
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"reset","op":"reset"}"#.utf8 + [0x0a])
        )

        let reply = try await replies.waitForReply(id: "reset")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["errorCode"] as? String, "remote_xpc_stream_reset")
        let details = try XCTUnwrap(reply["errorDetails"] as? [String: Any])
        XCTAssertEqual(details["streamIdentifier"] as? Int, 3)
        XCTAssertEqual(details["protocolErrorCode"] as? Int, 8)
        try stdin.fileHandleForWriting.close()
    }

    func testCancelsAnInFlightRequestExactlyOnce() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()
        let handlers: [String: TunnelAgentIPC.Handler] = [
            "slow": { _ in
                try await Task.sleep(for: .seconds(30))
                return nil
            },
        ]

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: handlers,
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"slow","op":"slow"}"#.utf8 + [0x0a])
        )
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"id":"cancel","op":"cancel","targetId":"slow"}"#.utf8 + [0x0a]
            )
        )

        let acknowledgement = try await replies.waitForReply(id: "cancel")
        XCTAssertEqual(acknowledgement["ok"] as? Bool, true)
        let cancelled = try await replies.waitForReply(id: "slow")
        XCTAssertEqual(cancelled["ok"] as? Bool, false)
        XCTAssertEqual(cancelled["errorCode"] as? String, "cancelled")
        try stdin.fileHandleForWriting.close()
        await serving.value
        XCTAssertEqual(replies.replies(id: "slow").count, 1)
    }

    func testRejectsCancellationForAnUnknownRequest() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: [:],
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"id":"cancel","op":"cancel","targetId":"missing"}"#.utf8 + [0x0a]
            )
        )

        let reply = try await replies.waitForReply(id: "cancel")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(
            reply["errorCode"] as? String,
            "cancellation_target_not_found"
        )
        let details = try XCTUnwrap(reply["errorDetails"] as? [String: Any])
        XCTAssertEqual(details["targetId"] as? String, "missing")
        try stdin.fileHandleForWriting.close()
    }

    func testRejectsCancellationThatTargetsItsOwnRequest() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: [:],
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"id":"cancel","op":"cancel","targetId":"cancel"}"#.utf8 + [0x0a]
            )
        )

        let reply = try await replies.waitForReply(id: "cancel")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["errorCode"] as? String, "invalid_input")
        try stdin.fileHandleForWriting.close()
    }

    func testRejectsDuplicateInFlightRequestIdentifiers() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()
        let handlers: [String: TunnelAgentIPC.Handler] = [
            "slow": { _ in
                try await Task.sleep(for: .seconds(30))
                return nil
            },
        ]

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: handlers,
                send: replies.record
            )
        }
        defer {
            serving.cancel()
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"same","op":"slow"}"#.utf8 + [0x0a])
        )
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"same","op":"slow"}"#.utf8 + [0x0a])
        )
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"id":"cancel","op":"cancel","targetId":"same"}"#.utf8 + [0x0a]
            )
        )

        _ = try await replies.waitForReply(id: "cancel")
        _ = try await replies.waitForReplies(id: "same", count: 2)
        try stdin.fileHandleForWriting.close()
        await serving.value
        let targetReplies = replies.replies(id: "same")
        XCTAssertEqual(targetReplies.count, 2)
        let duplicate = try XCTUnwrap(
            targetReplies.first {
                $0["errorCode"] as? String == "duplicate_request_id"
            }
        )
        XCTAssertEqual(duplicate["event"] as? String, "op-error")
        let cancelled = try XCTUnwrap(
            targetReplies.first {
                $0["errorCode"] as? String == "cancelled"
            }
        )
        XCTAssertEqual(cancelled["event"] as? String, "op-result")
        XCTAssertEqual(
            Set(targetReplies.compactMap { $0["errorCode"] as? String }),
            ["duplicate_request_id", "cancelled"]
        )
    }

    func testEndOfFileCancelsInFlightRequests() async throws {
        let stdin = Pipe()
        let replies = ReplyRecorder()
        let handlers: [String: TunnelAgentIPC.Handler] = [
            "slow": { _ in
                try await Task.sleep(for: .seconds(30))
                return nil
            },
        ]

        let serving = Task {
            await TunnelAgentIPC.serve(
                requestsFrom: stdin.fileHandleForReading,
                handlers: handlers,
                send: replies.record
            )
        }
        try stdin.fileHandleForWriting.write(
            contentsOf: Data(#"{"id":"slow","op":"slow"}"#.utf8 + [0x0a])
        )
        try stdin.fileHandleForWriting.close()

        await serving.value
        let reply = try await replies.waitForReply(id: "slow")
        XCTAssertEqual(reply["errorCode"] as? String, "cancelled")
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

    func replies(id: String) -> [[String: Any]] {
        decoded().filter { $0["id"] as? String == id }
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

    func waitForReplies(
        id: String,
        count: Int
    ) async throws -> [[String: Any]] {
        for _ in 0..<400 {
            let matches = replies(id: id)
            if matches.count >= count {
                return matches
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RorkDeviceError.transport(
            "Expected \(count) replies for request \(id)."
        )
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
