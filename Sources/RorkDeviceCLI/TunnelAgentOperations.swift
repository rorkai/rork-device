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

    /// One device-backed operation: its wire name and its handler factory.
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
