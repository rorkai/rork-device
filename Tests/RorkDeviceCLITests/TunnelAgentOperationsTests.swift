import Foundation
import XCTest

@testable import RorkDevice
@testable import RorkDeviceCLI

/// Device-backed IPC operations served through the shared tunnel session.
final class TunnelAgentOperationsTests: XCTestCase {
    func testAppsListReturnsInstalledApplicationsFromTheSharedSession() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(try scriptedSession())
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(#"{"id":"7","op":"apps-list","type":"all"}"#)

        let payload = try await XCTUnwrap(handlers["apps-list"])(request)

        let encoded = try JSONEncoder().encode(
            ErasedPayload(payload: XCTUnwrap(payload))
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let apps = try XCTUnwrap(object["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0]["bundleIdentifier"] as? String, "com.example.app")
        XCTAssertEqual(apps[0]["displayName"] as? String, "Example App")
        XCTAssertEqual(apps[0]["version"] as? String, "1.2.3")
        XCTAssertEqual(apps[0]["buildVersion"] as? String, "456")
    }

    func testAppsListBrowsesTheRequestedApplicationType() async throws {
        let backend = ScriptedServiceBackend(inbound: try browseResponse())
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: backend))
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(#"{"id":"8","op":"apps-list","type":"system"}"#)

        _ = try await XCTUnwrap(handlers["apps-list"])(request)

        let browse = try XCTUnwrap(backend.sentMessages().first)
        XCTAssertEqual(browse["Command"] as? String, "Browse")
        let options = try XCTUnwrap(browse["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "System")
    }

    func testAppsListDefaultsToUserApplications() async throws {
        let backend = ScriptedServiceBackend(inbound: try browseResponse())
        let gate = TunnelAgentSessionGate()
        gate.publish(DeviceSession(backend: backend))
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(#"{"id":"9","op":"apps-list"}"#)

        _ = try await XCTUnwrap(handlers["apps-list"])(request)

        let browse = try XCTUnwrap(backend.sentMessages().first)
        let options = try XCTUnwrap(browse["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "User")
    }

    func testAppsListRejectsAnUnknownApplicationType() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(try scriptedSession())
        let handlers = TunnelAgentOperations.handlers(sessionGate: gate)
        let request = try decodedRequest(#"{"id":"10","op":"apps-list","type":"frobnicated"}"#)

        do {
            _ = try await XCTUnwrap(handlers["apps-list"])(request)
            XCTFail("Expected an unknown-type error")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("frobnicated"),
                "Expected the rejected type in \(error)"
            )
        }
    }

    func testReestablishingEventsFeedTheReasonWaitingRequestsFailWith() async throws {
        // A tunnel that never establishes emits no tunnel-lost events, only
        // re-establishing ones, and those must still name the failure for
        // requests that time out while the device stays away.
        let gate = TunnelAgentSessionGate()
        gate.markLost(reason: nil)
        gate.markLost(reason: "No matching device found.")
        let handlers = TunnelAgentOperations.handlers(
            sessionGate: gate,
            patience: .milliseconds(50)
        )
        let request = try decodedRequest(#"{"id":"12","op":"apps-list"}"#)

        do {
            _ = try await XCTUnwrap(handlers["apps-list"])(request)
            XCTFail("Expected a timeout error")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("No matching device found."),
                "Expected the establishment failure in \(error)"
            )
        }
    }

    func testAppsListFailsWithTheLastLossReasonWhenTheTunnelStaysDown() async throws {
        let gate = TunnelAgentSessionGate()
        gate.markLost(reason: "the cable was unplugged")
        let handlers = TunnelAgentOperations.handlers(
            sessionGate: gate,
            patience: .milliseconds(50)
        )
        let request = try decodedRequest(#"{"id":"11","op":"apps-list"}"#)

        do {
            _ = try await XCTUnwrap(handlers["apps-list"])(request)
            XCTFail("Expected a timeout error")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("the cable was unplugged"),
                "Expected the loss reason in \(error)"
            )
        }
    }

    /// Runs the README's example session, where one apps-list request is
    /// answered on the wire with the apps at the top level of the op-result
    /// reply.
    func testAppsListAnswersThroughTheServeLoop() async throws {
        let gate = TunnelAgentSessionGate()
        gate.publish(try scriptedSession())
        let handlers = TunnelAgentIPC.builtInHandlers(
            capabilities: TunnelStartCommand.serveCapabilities
        ).merging(TunnelAgentOperations.handlers(sessionGate: gate)) { _, operation in
            operation
        }
        let stdin = Pipe()
        let replies = ReplyLines()
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
            contentsOf: Data(#"{"id":"7","op":"apps-list","type":"all"}"#.utf8 + [0x0a])
        )

        let reply = try await replies.waitForReply(id: "7")
        XCTAssertEqual(reply["event"] as? String, "op-result")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let apps = try XCTUnwrap(reply["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.first?["bundleIdentifier"] as? String, "com.example.app")
        try stdin.fileHandleForWriting.close()
    }

    /// Decodes a request line the same way the serve loop does.
    private func decodedRequest(_ line: String) throws -> TunnelAgentIPC.Request {
        guard case .request(let request) = TunnelAgentIPC.decodeRequest(from: line) else {
            throw RorkDeviceError.invalidInput("The test request line did not decode.")
        }
        return request
    }

    /// A session whose InstallationProxy service answers one Browse page.
    private func scriptedSession() throws -> DeviceSession {
        DeviceSession(backend: ScriptedServiceBackend(inbound: try browseResponse()))
    }

    /// One complete InstallationProxy Browse response with a single app.
    private func browseResponse() throws -> Data {
        try PropertyListMessageFramer.encode([
            "CurrentAmount": 1,
            "CurrentIndex": 0,
            "CurrentList": [
                [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleDisplayName": "Example App",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                ],
            ],
            "Status": "Complete",
        ])
    }
}

/// Session backend whose every service connection replays scripted bytes.
private final class ScriptedServiceBackend: DeviceSessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let inbound: Data
    private var connections: [ScriptedConnection] = []

    init(inbound: Data) {
        self.inbound = inbound
    }

    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        let connection = ScriptedConnection(inbound: inbound)
        lock.withLock {
            connections.append(connection)
        }
        return connection
    }

    /// Property lists sent by clients over every opened connection, in order.
    func sentMessages() -> [[String: Any]] {
        let sent = lock.withLock {
            connections.flatMap(\.sent)
        }
        return sent.compactMap { data in
            // Strip the framer's 4-byte length prefix before decoding.
            guard data.count > 4 else {
                return nil
            }
            return try? PropertyListSerialization.propertyList(
                from: data.dropFirst(4),
                format: nil
            ) as? [String: Any]
        }
    }
}

/// A scripted service stream whose reads consume the fixture bytes and
/// whose writes accumulate for assertions.
private final class ScriptedConnection: DeviceConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: Data
    private(set) var sent: [Data] = []

    init(inbound: Data) {
        self.inbound = inbound
    }

    func send(_ data: Data) async throws {
        lock.withLock {
            sent.append(data)
        }
    }

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
private struct ErasedPayload: Encodable {
    let payload: any Encodable

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// Collects reply lines from the serve loop for correlation by id.
private final class ReplyLines: @unchecked Sendable {
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
