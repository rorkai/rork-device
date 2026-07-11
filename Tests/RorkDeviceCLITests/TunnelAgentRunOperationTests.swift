import Foundation
import XCTest

@testable import RorkDevice
@testable import RorkDeviceCLI

/// The generic run operation, which executes an allowlisted CLI command
/// in-process against the shared tunnel session.
final class TunnelAgentRunOperationTests: XCTestCase {
    func testRunExecutesAppsListAndRepliesWithItsOutput() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(try scriptedBrowseSession())
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(
            #"{"id":"1","op":"run","argv":["apps","list","--type=all","--json"]}"#
        )

        let payload = try await XCTUnwrap(handlers["run"])(request)

        let object = try encodedObject(of: XCTUnwrap(payload))
        let output = try XCTUnwrap(object["output"] as? String)
        let apps = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0]["bundleIdentifier"] as? String, "com.example.app")
    }

    func testRunReusesTheSharedSessionInsteadOfDialing() async throws {
        let backend = ScriptedBrowseBackend()
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: backend))
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(
            #"{"id":"2","op":"run","argv":["apps","list","--json"]}"#
        )

        _ = try await XCTUnwrap(handlers["run"])(request)

        XCTAssertEqual(backend.openedServices(), ["com.apple.mobile.installation_proxy"])
    }

    func testRunRejectsCommandFamiliesOutsideTheAllowlist() async throws {
        let gate = TunnelAgentSessionGate()
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)

        for argv in [
            #"["tunnel","start","--identity","x.plist"]"#,
            #"["pairing","establish"]"#,
            #"["remote-pairing","diagnose"]"#,
            #"["image","list"]"#,
            #"["list"]"#,
        ] {
            let request = try decodedRequest(
                ##"{"id":"3","op":"run","argv":\##(argv)}"##
            )
            do {
                _ = try await XCTUnwrap(handlers["run"])(request)
                XCTFail("Expected \(argv) to be rejected")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("cannot serve"),
                    "Expected an allowlist rejection for \(argv), got \(error)"
                )
            }
        }
    }

    func testRunRejectsConnectionFlagsBecauseTheSessionIsPinned() async throws {
        let gate = TunnelAgentSessionGate()
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)

        for flag in ["--udid", "--host", "--pairing-record", "--userspace-gateway-port"] {
            let request = try decodedRequest(
                #"{"id":"4","op":"run","argv":["apps","list","\#(flag)","x"]}"#
            )
            do {
                _ = try await XCTUnwrap(handlers["run"])(request)
                XCTFail("Expected \(flag) to be rejected")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(flag),
                    "Expected the rejected flag named in \(error)"
                )
            }
        }
    }

    func testRunReportsParseFailuresWithoutRunningAnything() async throws {
        let gate = TunnelAgentSessionGate()
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(
            #"{"id":"5","op":"run","argv":["apps","list","--no-such-flag"]}"#
        )

        do {
            _ = try await XCTUnwrap(handlers["run"])(request)
            XCTFail("Expected a parse failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("--no-such-flag"),
                "Expected the unknown flag named in \(error)"
            )
        }
    }

    func testRouteSelectionIsRejectedOnlyWhileServing() throws {
        // The options type itself enforces the pinned connection during
        // validation, so the same argv parses from the shell and fails
        // under the serving marker.
        XCTAssertThrowsError(
            try ConnectionOptions.$rejectsRouteSelection.withValue(true) {
                try AppsList.parse(["--udid", "00008150-TEST"])
            }
        ) { error in
            XCTAssertTrue(
                RorkDeviceCommand.message(for: error).contains("--udid")
            )
        }

        XCTAssertNoThrow(try AppsList.parse(["--udid", "00008150-TEST"]))
    }

    func testRunnableCommandFamiliesDeriveFromTheCommandTree() {
        // Every runnable command must remain a subcommand of the CLI root,
        // or run would accept argv the command tree cannot parse.
        let rootNames = Set(
            RorkDeviceCommand.configuration.subcommands.compactMap {
                $0.configuration.commandName
            }
        )
        XCTAssertTrue(
            TunnelAgentOperations.runnableCommandFamilies.isSubset(of: rootNames)
        )
        XCTAssertFalse(TunnelAgentOperations.runnableCommandFamilies.contains("tunnel"))
    }

    func testRunRequiresANonEmptyArgv() async throws {
        let gate = TunnelAgentSessionGate()
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(#"{"id":"6","op":"run","argv":[]}"#)

        do {
            _ = try await XCTUnwrap(handlers["run"])(request)
            XCTFail("Expected an empty-argv rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("argv"))
        }
    }

    /// Runs the wire-level session from the README, where a run request is
    /// answered with the command's output in the op-result reply.
    func testRunAnswersThroughTheServeLoop() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(try scriptedBrowseSession())
        let handlers = TunnelAgentIPC.builtInHandlers(
            capabilities: TunnelStartCommand.serveCapabilities
        ).merging(
            TunnelAgentOperations.handlers(sessionGate: gate)
        ) { _, operation in
            operation
        }
        let stdin = Pipe()
        let replies = RunReplyLines()
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
            contentsOf: Data(
                #"{"id":"7","op":"run","argv":["apps","list","--type=all","--json"]}"#.utf8 + [0x0a]
            )
        )

        let reply = try await replies.waitForReply(id: "7")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let output = try XCTUnwrap(reply["output"] as? String)
        XCTAssertTrue(output.contains("com.example.app"))
        try stdin.fileHandleForWriting.close()
    }

    /// Decodes a request line the same way the serve loop does.
    private func decodedRequest(_ line: String) throws -> TunnelAgentIPC.Request {
        guard case .request(let request) = TunnelAgentIPC.decodeRequest(from: line) else {
            throw RorkDeviceError.invalidInput("The test request line did not decode.")
        }
        return request
    }

    /// Encodes a handler payload and decodes it back into a dictionary.
    private func encodedObject(of payload: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(RunErasedPayload(payload: payload))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A session whose InstallationProxy service answers one Browse page.
    private func scriptedBrowseSession() throws -> DeviceSession {
        DeviceSession(backend: ScriptedBrowseBackend())
    }
}

/// The command-output capture used by in-process runs.
final class CommandOutputTests: XCTestCase {
    func testWritesReachTheInstalledSinkInsteadOfStandardOutput() async throws {
        let captured = LockedLines()

        try await CommandOutput.$sink.withValue(captured.append) {
            try CommandOutput.write(contentsOf: Data("line".utf8))
            CommandOutput.print("printed")
        }

        XCTAssertEqual(captured.utf8Strings(), ["line", "printed\n"])
    }
}

/// Session backend that answers InstallationProxy Browse and records the
/// services it opened.
private final class ScriptedBrowseBackend: DeviceSessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [String] = []

    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        lock.withLock {
            services.append(serviceName)
        }
        return RunScriptedConnection(
            inbound: try PropertyListMessageFramer.encode([
                "CurrentAmount": 1,
                "CurrentIndex": 0,
                "CurrentList": [
                    ["CFBundleIdentifier": "com.example.app"],
                ],
                "Status": "Complete",
            ])
        )
    }

    func openedServices() -> [String] {
        lock.withLock { services }
    }
}

/// A scripted service stream whose reads consume the fixture bytes.
private final class RunScriptedConnection: DeviceConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: Data

    init(inbound: Data) {
        self.inbound = inbound
    }

    func send(_ data: Data) async throws {}

    func receive(exactly byteCount: Int) async throws -> Data {
        try lock.withLock {
            guard inbound.count >= byteCount else {
                throw RorkDeviceError.transport("The scripted bytes are exhausted.")
            }
            let chunk = Data(inbound.prefix(byteCount))
            inbound.removeFirst(byteCount)
            return chunk
        }
    }

    func close() {}
}

/// Opens the generic encoder to a handler's existential payload.
private struct RunErasedPayload: Encodable {
    let payload: any Encodable

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// Collects captured output lines behind a lock.
private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func append(_ line: Data) {
        lock.withLock {
            lines.append(line)
        }
    }

    func utf8Strings() -> [String] {
        lock.withLock {
            lines.compactMap { String(data: $0, encoding: .utf8) }
        }
    }
}

/// Collects reply lines from the serve loop for correlation by id.
private final class RunReplyLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func record(_ line: Data) {
        lock.withLock {
            lines.append(line)
        }
    }

    func waitForReply(id: String) async throws -> [String: Any] {
        for _ in 0..<400 {
            let decoded = lock.withLock { lines }.compactMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            if let reply = decoded.first(where: { $0["id"] as? String == id }) {
                return reply
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RorkDeviceError.transport("No reply for request \(id).")
    }
}
