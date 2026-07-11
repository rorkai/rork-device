import ArgumentParser
import Foundation
import RorkDevice

/// Device-backed operations the tunnel agent serves over standard input.
///
/// Each handler decodes its wire parameters, borrows the current cycle's
/// shared session from the gate, and answers with the same JSON shapes the
/// equivalent CLI commands emit, so supervisors can switch an operation from
/// the exec path to the pipe without reparsing anything.
enum TunnelAgentOperations {
    /// How long a request may wait for the tunnel to come back.
    ///
    /// Matches the patience a supervisor applies before declaring an
    /// operation failed while the reconnect loop is re-establishing.
    static let sessionPatience: Duration = .seconds(30)

    /// A served operation pairs its wire name with the factory that builds
    /// its handler.
    private struct Operation: Sendable {
        let name: String
        let makeHandler: @Sendable (
            TunnelAgentSessionGate,
            Duration
        ) -> TunnelAgentIPC.Handler
    }

    /// Every served operation, in advertisement order.
    ///
    /// `names` and `handlers(sessionGate:patience:)` both derive from this
    /// table, so an operation can neither be served without being advertised
    /// nor advertised without being served.
    private static let operations = [
        Operation(name: "apps-list", makeHandler: appsListHandler),
        Operation(name: "run", makeHandler: runHandler),
    ]

    /// Command families the `run` operation accepts.
    ///
    /// Everything here works over the tunnel's Remote Service Discovery
    /// session. The excluded families genuinely need something else. Tunnel
    /// commands cannot nest inside a serving agent, pairing and image
    /// commands require a Lockdown route, and device discovery belongs to
    /// the supervisor, which already watches attach events itself.
    static let runnableCommandFamilies: Set<String> = [
        "apps",
        "files",
        "info",
        "install",
        "launch",
        "profiles",
        "terminate",
        "uninstall",
    ]

    /// Connection flags rejected by `run`.
    ///
    /// The served command reuses the agent's session, which is pinned to
    /// the tunnel's device, so argv must not try to select a different
    /// route or device.
    private static let rejectedRunFlagPrefixes = [
        "--udid",
        "--host",
        "--port",
        "--pairing-record",
        "--userspace-",
        "--remote-service-discovery",
    ]

    /// Wire names of the served operations, for capability advertisements.
    static var names: [String] {
        operations.map(\.name)
    }

    /// Builds the handlers for every device-backed operation.
    ///
    /// - Parameters:
    ///   - gate: Hands out the shared session of the current tunnel cycle.
    ///   - patience: How long each request waits for a session.
    static func handlers(
        sessionGate gate: TunnelAgentSessionGate,
        patience: Duration = sessionPatience
    ) -> [String: TunnelAgentIPC.Handler] {
        Dictionary(
            uniqueKeysWithValues: operations.map { operation in
                (operation.name, operation.makeHandler(gate, patience))
            }
        )
    }

    /// Runs an allowlisted CLI command in-process against the shared session.
    ///
    /// The argv is parsed with the same command tree the shell uses, and the
    /// command's output becomes the reply's `output` field. Two task locals
    /// carry the request's environment. The shared session replaces the
    /// command's own dialing, and the output sink captures what the command
    /// would have written to standard output, which must not interleave with
    /// the agent's machine-readable channel.
    private static func runHandler(
        gate: TunnelAgentSessionGate,
        patience: Duration
    ) -> TunnelAgentIPC.Handler {
        { request in
            let parameters: RunParameters = try request.parameters()
            let argv = try validatedRunArgv(parameters.argv)

            // Parsing precedes the session wait, so a malformed command
            // line answers immediately instead of riding out a reconnect.
            let command: ParsableCommand
            do {
                command = try RorkDeviceCommand.parseAsRoot(argv)
            } catch {
                throw RorkDeviceError.invalidInput(
                    RorkDeviceCommand.message(for: error)
                )
            }

            let session = try await gate.waitForSession(upTo: patience)
            let capture = RunOutputCapture()
            try await ConnectionOptions.$injectedSession.withValue(session) {
                try await CommandOutput.$sink.withValue(capture.append) {
                    if var asyncCommand = command as? any AsyncParsableCommand {
                        try await asyncCommand.run()
                    } else {
                        var command = command
                        try command.run()
                    }
                }
            }
            return RunPayload(output: capture.utf8String())
        }
    }

    /// Validates a `run` request's argv against the allowlist and the
    /// pinned-connection rule.
    private static func validatedRunArgv(_ argv: [String]?) throws -> [String] {
        guard let argv, let family = argv.first, !family.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "run requires a non-empty argv array."
            )
        }
        guard runnableCommandFamilies.contains(family) else {
            throw RorkDeviceError.invalidInput(
                "run cannot serve \(family) commands. It serves: \(runnableCommandFamilies.sorted().joined(separator: ", "))."
            )
        }
        if let rejected = argv.first(where: { token in
            rejectedRunFlagPrefixes.contains(where: token.hasPrefix)
        }) {
            throw RorkDeviceError.invalidInput(
                "run pins the connection to the served tunnel, so \(rejected) is not accepted."
            )
        }
        return argv
    }

    /// Lists installed applications through the shared session.
    private static func appsListHandler(
        gate: TunnelAgentSessionGate,
        patience: Duration
    ) -> TunnelAgentIPC.Handler {
        { request in
            let parameters: AppsListParameters = try request.parameters()
            let type = try parameters.applicationType()
            let session = try await gate.waitForSession(upTo: patience)
            let apps = try await session.installedApplications(matching: type)
            return AppsListPayload(
                apps: apps.map(InstalledApplicationListEntry.init)
            )
        }
    }
}

/// Wire parameters of `apps-list`.
private struct AppsListParameters: Decodable {
    /// Application class to browse, in the same spelling the CLI accepts.
    let type: String?

    /// Resolves the requested class, defaulting to user applications.
    func applicationType() throws -> ApplicationType {
        guard let type else {
            return .user
        }
        guard let parsed = ApplicationType(argument: type) else {
            throw RorkDeviceError.invalidInput(
                "Unknown application type \(type)."
            )
        }
        return parsed
    }
}

/// Reply payload of `apps-list`, one entry per installed application.
private struct AppsListPayload: Encodable {
    let apps: [InstalledApplicationListEntry]
}

/// Wire parameters of `run`.
private struct RunParameters: Decodable {
    /// The command line to execute, without the executable name.
    let argv: [String]?
}

/// Reply payload of `run`, carrying the executed command's output verbatim.
private struct RunPayload: Encodable {
    let output: String
}

/// Accumulates a command's captured output across concurrent writes.
private final class RunOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Appends one output chunk, in write order.
    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
        }
    }

    /// Returns everything captured so far as UTF-8 text.
    func utf8String() -> String {
        lock.withLock {
            String(decoding: buffer, as: UTF8.self)
        }
    }
}
