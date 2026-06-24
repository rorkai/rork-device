import ArgumentParser
import Foundation
import RorkDevice

/// Reproduces the complete Lockdown-to-remote-pairing transition.
///
/// Companion normally performs these stages as part of installation, which
/// makes attachment-scoped failures difficult to isolate. This command stops
/// after remote trust and emits only identifiers, phases, and the final error.
struct RemotePairingDiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract:
            "Diagnose remote pairing over a freshly opened USB CoreDevice tunnel."
    )

    @Option(help: "Device UDID. Defaults to the first USB device.")
    var udid: String?

    @Option(
        name: .customLong("identity"),
        help:
            "Stable remote-pairing identity plist. A new identity is created when the file does not exist."
    )
    var identityPath: String

    @Flag(
        help:
            "Replace Lockdown pairing before opening the tunnel and display the iPhone Trust prompt."
    )
    var refreshLockdownPairing = false

    @Option(help: "Seconds to wait for the device-side Lockdown Trust decision.")
    var trustTimeout = 120.0

    @Option(
        name: .customLong("mtu"),
        help: "Maximum IPv6 packet size requested from CoreDevice."
    )
    var maximumTransmissionUnit: UInt16 = 1_280

    @Flag(help: "Emit a machine-readable redacted diagnostic report.")
    var json = false

    /// Rejects values that cannot produce a bounded USB tunnel attempt.
    func validate() throws {
        guard !identityPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("--identity cannot be empty.")
        }
        _ = try lockdownTrustTimeout
        guard maximumTransmissionUnit >= 1_280 else {
            throw ValidationError("--mtu must be at least 1280.")
        }
    }

    /// Runs the complete attachment-sensitive flow and reports where it stopped.
    func run() async throws {
        let identityURL = URL(fileURLWithPath: identityPath)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: identityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let identity = try RemotePairingIdentity.loadOrCreate(
            at: identityURL
        )
        let recorder = RemotePairingDiagnosticRecorder()
        let client = DeviceClient()
        let device = try await selectedUSBDevice(
            from: client,
            matching: udid
        )
        let pairingTrustTimeout = try lockdownTrustTimeout

        do {
            try await performLockdownPairing(
                ifRequested: refreshLockdownPairing,
                recorder: recorder
            ) {
                _ = try await client.pair(
                    with: device,
                    trustTimeout: pairingTrustTimeout
                ) { progress in
                    writePairingProgress(progress)
                }
            }
            recorder.record(phase: .lockdownSession)
            let session: DeviceSession
            if refreshLockdownPairing {
                session = try await waitForSavedPairingActivation(
                    attemptDelays:
                        savedPairingActivationAttemptDelays,
                    sleep: {
                        try await Task.sleep(for: $0)
                    },
                    onRetry: writePairingActivationRetry,
                    attempt: {
                        try await openValidatedSavedPairingSession(
                            for: device.identifier,
                            label:
                                "rorkdevice remote-pairing diagnose"
                        )
                    }
                )
            } else {
                session = try await openValidatedSavedPairingSession(
                    for: device.identifier,
                    label: "rorkdevice remote-pairing diagnose"
                )
            }
            recorder.record(phase: .coreDeviceTunnel)
            let tunnel = try await session.openCoreDeviceTunnel(
                requestedMaximumTransmissionUnit:
                    maximumTransmissionUnit
            )
            let openedNetwork: CoreDeviceUserspaceNetwork
            do {
                openedNetwork = try CoreDeviceUserspaceNetwork(
                    tunnel: tunnel
                )
            } catch {
                tunnel.close()
                throw error
            }
            defer {
                openedNetwork.close()
            }
            try await RemotePairingTrust.establishIfNeeded(
                for: identity,
                using: openedNetwork,
                discoveryPort:
                    openedNetwork.configuration.serviceDiscoveryPort
            ) { progress in
                recorder.record(progress: progress)
                writeRemotePairingProgress(progress)
            }
        } catch {
            recorder.record(failure: error)
            try writeRemotePairingDiagnosticReport(
                recorder.makeReport(
                    deviceIdentifier: device.identifier,
                    identityIdentifier: identity.identifier,
                    didRefreshLockdownPairing:
                        refreshLockdownPairing
                ),
                asJSON: json
            )
            throw ExitCode.failure
        }

        try writeRemotePairingDiagnosticReport(
            recorder.makeReport(
                deviceIdentifier: device.identifier,
                identityIdentifier: identity.identifier,
                didRefreshLockdownPairing:
                    refreshLockdownPairing
            ),
            asJSON: json
        )
    }

    /// Converts the CLI value only after proving its millisecond representation is safe.
    private var lockdownTrustTimeout: Duration {
        get throws {
            guard trustTimeout.isFinite, trustTimeout >= 0 else {
                throw ValidationError(
                    "--trust-timeout must be a nonnegative finite number."
                )
            }
            let milliseconds = trustTimeout * 1_000
            guard milliseconds < Double(Int64.max) else {
                throw ValidationError("--trust-timeout is too large.")
            }
            return .milliseconds(Int64(milliseconds))
        }
    }
}

/// Couples the diagnostic phase to the optional operation that actually changes trust.
func performLockdownPairing(
    ifRequested isRequested: Bool,
    recorder: RemotePairingDiagnosticRecorder,
    operation: () async throws -> Void
) async rethrows {
    guard isRequested else {
        return
    }
    recorder.record(phase: .lockdownPairing)
    try await operation()
}

/// Operator-visible state reached by the diagnostic attempt.
enum RemotePairingDiagnosticPhase: String, Encodable, Sendable {
    case notStarted = "not-started"
    case lockdownPairing = "lockdown-pairing"
    case lockdownSession = "lockdown-session"
    case coreDeviceTunnel = "core-device-tunnel"
    case openingServiceDiscovery = "opening-service-discovery"
    case openingPairingService = "opening-pairing-service"
    case verifyingIdentity = "verifying-identity"
    case enrollingIdentity = "enrolling-identity"
    case remotePairingEstablished = "remote-pairing-established"
}

/// Redacted result suitable for attaching to a bug report.
///
/// Swift-facing property names follow API naming conventions while `CodingKeys`
/// preserves the concise field names already emitted by the CLI.
struct RemotePairingDiagnosticReport: Encodable, Equatable {
    let rorkDeviceVersion: String
    let deviceIdentifier: String
    let identityIdentifier: String
    let didRefreshLockdownPairing: Bool
    let succeeded: Bool
    let lastPhase: RemotePairingDiagnosticPhase
    let reachedPhases: [RemotePairingDiagnosticPhase]
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case rorkDeviceVersion
        case deviceIdentifier
        case identityIdentifier
        case didRefreshLockdownPairing = "refreshedLockdownPairing"
        case succeeded
        case lastPhase
        case reachedPhases = "phases"
        case errorDescription = "error"
    }
}

/// Captures progress from both synchronous CLI work and sendable callbacks.
///
/// Every mutable property is accessed while `lock` is held, which makes the
/// class safe to capture in callbacks that may execute on different tasks.
final class RemotePairingDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reachedPhases: [RemotePairingDiagnosticPhase] = []
    private var currentPhase = RemotePairingDiagnosticPhase.notStarted
    private var failureDescription: String?

    /// Records a stage before work begins so failures retain their location.
    func record(phase: RemotePairingDiagnosticPhase) {
        recordTransition(to: phase)
    }

    /// Maps library progress into the stable CLI diagnostic vocabulary.
    func record(progress: RemotePairingTrust.Progress) {
        let phase: RemotePairingDiagnosticPhase
        switch progress {
        case .openingServiceDiscovery:
            phase = .openingServiceDiscovery
        case .openingPairingService:
            phase = .openingPairingService
        case .verifyingIdentity:
            phase = .verifyingIdentity
        case .enrollingIdentity:
            phase = .enrollingIdentity
        case .established:
            phase = .remotePairingEstablished
        }
        recordTransition(to: phase)
    }

    /// Preserves the typed library description instead of NSError bridging.
    func record(failure error: Error) {
        let description = diagnosticDescription(of: error)
        lock.withLock {
            failureDescription = description
        }
    }

    /// Creates an immutable snapshot without exposing credential bytes.
    func makeReport(
        deviceIdentifier: String,
        identityIdentifier: String,
        didRefreshLockdownPairing: Bool
    ) -> RemotePairingDiagnosticReport {
        lock.withLock {
            RemotePairingDiagnosticReport(
                rorkDeviceVersion: RorkDevice.version,
                deviceIdentifier: deviceIdentifier,
                identityIdentifier: identityIdentifier,
                didRefreshLockdownPairing:
                    didRefreshLockdownPairing,
                succeeded:
                    failureDescription == nil
                    && currentPhase == .remotePairingEstablished,
                lastPhase: currentPhase,
                reachedPhases: reachedPhases,
                errorDescription: failureDescription
            )
        }
    }

    /// Appends only transitions so repeated retry callbacks remain concise.
    private func recordTransition(
        to phase: RemotePairingDiagnosticPhase
    ) {
        lock.withLock {
            currentPhase = phase
            if reachedPhases.last != phase {
                reachedPhases.append(phase)
            }
        }
    }
}

/// Encodes deterministic JSON for support collection and regression fixtures.
func remotePairingDiagnosticJSON(
    _ report: RemotePairingDiagnosticReport
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(report)
}

/// Formats the same redacted fields for an interactive terminal.
func remotePairingDiagnosticText(
    _ report: RemotePairingDiagnosticReport
) -> String {
    var lines = [
        "Remote-pairing diagnostics for \(report.deviceIdentifier):",
        "- rork-device: \(report.rorkDeviceVersion)",
        "- identity: \(report.identityIdentifier)",
        "- refreshed Lockdown pairing: \(report.didRefreshLockdownPairing ? "yes" : "no")",
        "- phases: \(report.reachedPhases.map(\.rawValue).joined(separator: ", "))",
        "- last phase: \(report.lastPhase.rawValue)",
        "- result: \(report.succeeded ? "passed" : "failed")",
    ]
    if let error = report.errorDescription {
        lines.append("- error: \(error)")
    }
    return lines.joined(separator: "\n")
}

/// Keeps stdout machine-readable while still returning a useful failure code.
private func writeRemotePairingDiagnosticReport(
    _ report: RemotePairingDiagnosticReport,
    asJSON: Bool
) throws {
    if asJSON {
        try FileHandle.standardOutput.write(
            contentsOf: remotePairingDiagnosticJSON(report)
        )
        try FileHandle.standardOutput.write(
            contentsOf: Data([0x0a])
        )
    } else {
        print(remotePairingDiagnosticText(report))
    }
}
