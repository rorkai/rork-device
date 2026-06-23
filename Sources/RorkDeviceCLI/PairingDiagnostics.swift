import ArgumentParser
import Crypto
import Foundation
import RorkDevice

/// Runs non-destructive Lockdown TLS compatibility checks for one pairing.
struct PairingDiagnose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Diagnose Lockdown TLS compatibility without changing pairing."
    )

    @OptionGroup var connection: ConnectionOptions

    @Flag(help: "Emit a machine-readable diagnostic report.")
    var json = false

    func run() async throws {
        let target = try await connection.lockdownTarget()
        let attempts = await runPairingDiagnosticProfiles { profile in
            await diagnosePairing(
                device: target.device,
                pairingRecord: target.pairingRecord,
                profile: profile
            )
        }
        let report = PairingDiagnosticReport(
            deviceIdentifier: target.device.identifier,
            pairingRecord: pairingRecordDiagnostic(target.pairingRecord),
            attempts: attempts
        )

        if json {
            let data = try pairingDiagnosticJSON(report)
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.write(contentsOf: Data([0x0A]))
        } else {
            printPairingDiagnosticReport(report)
        }
    }
}

/// User-visible stage reached by one profile attempt.
enum PairingDiagnosticPhase: String, Encodable {
    case lockdownSession = "lockdown-session"
    case tlsHandshake = "tls-handshake"
    case deviceInfo = "device-info"
    case complete
}

/// Redacted public-certificate details suitable for support logs.
struct PairingCertificateDiagnostic: Encodable, Equatable {
    let byteCount: Int
    let encoding: String
    let sha256: String
}

/// Pairing material included in diagnostics without private keys or escrow data.
struct PairingRecordDiagnostic: Encodable, Equatable {
    let deviceCertificate: PairingCertificateDiagnostic?
    let hostCertificate: PairingCertificateDiagnostic?
    let rootCertificate: PairingCertificateDiagnostic?
}

/// Result of one fresh Lockdown connection using one TLS policy.
struct PairingDiagnosticAttempt: Encodable, Equatable {
    let profile: String
    let succeeded: Bool
    let phase: String
    let error: String?
}

/// Complete report emitted after every profile has been attempted.
struct PairingDiagnosticReport: Encodable, Equatable {
    let deviceIdentifier: String
    let pairingRecord: PairingRecordDiagnostic
    let attempts: [PairingDiagnosticAttempt]
}

/// Runs every profile sequentially so one failed handshake cannot stop diagnosis.
func runPairingDiagnosticProfiles(
    attempt: (LockdownTLSProfile) async -> PairingDiagnosticAttempt
) async -> [PairingDiagnosticAttempt] {
    var attempts: [PairingDiagnosticAttempt] = []
    attempts.reserveCapacity(LockdownTLSProfile.allCases.count)
    for profile in LockdownTLSProfile.allCases {
        attempts.append(await attempt(profile))
    }
    return attempts
}

/// Builds a report that identifies certificate bytes without exposing secrets.
func pairingRecordDiagnostic(
    _ record: PairingRecord
) -> PairingRecordDiagnostic {
    PairingRecordDiagnostic(
        deviceCertificate: certificateDiagnostic(record.deviceCertificate),
        hostCertificate: certificateDiagnostic(record.hostCertificate),
        rootCertificate: certificateDiagnostic(record.rootCertificate)
    )
}

/// Encodes a deterministic JSON document for support collection.
func pairingDiagnosticJSON(
    _ report: PairingDiagnosticReport
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(report)
}

/// Attempts one authenticated session while recording the exact failure stage.
private func diagnosePairing(
    device: Device,
    pairingRecord: PairingRecord,
    profile: LockdownTLSProfile
) async -> PairingDiagnosticAttempt {
    let state = PairingTLSAttemptState()
    let client = DeviceClient(
        secureSessionUpgrader: PairingDiagnosticSecureSessionUpgrader(
            profile: profile,
            state: state
        )
    )
    var phase = PairingDiagnosticPhase.lockdownSession

    do {
        let session = try await client.connect(
            to: device,
            using: pairingRecord,
            label: "rorkdevice pairing diagnose"
        )
        phase = .deviceInfo
        let info = try await session.fetchDeviceInfo()
        try validatePairingIdentity(
            info,
            expectedDeviceIdentifier: device.identifier
        )
        return PairingDiagnosticAttempt(
            profile: profile.rawValue,
            succeeded: true,
            phase: PairingDiagnosticPhase.complete.rawValue,
            error: nil
        )
    } catch {
        if state.value == .failed {
            phase = .tlsHandshake
        }
        return PairingDiagnosticAttempt(
            profile: profile.rawValue,
            succeeded: false,
            phase: phase.rawValue,
            error: pairingDiagnosticErrorDescription(error)
        )
    }
}

/// Wraps the production NIOSSL upgrader while observing only its lifecycle.
private final class PairingDiagnosticSecureSessionUpgrader:
    SecureSessionUpgrader
{
    private let upgrader: NIOSecureSessionUpgrader
    private let state: PairingTLSAttemptState

    init(
        profile: LockdownTLSProfile,
        state: PairingTLSAttemptState
    ) {
        upgrader = NIOSecureSessionUpgrader(profile: profile)
        self.state = state
    }

    func upgrade(
        _ connection: DeviceConnection,
        pairingRecord: PairingRecord
    ) async throws -> DeviceConnection {
        state.value = .started
        do {
            let connection = try await upgrader.upgrade(
                connection,
                pairingRecord: pairingRecord
            )
            state.value = .succeeded
            return connection
        } catch {
            state.value = .failed
            throw error
        }
    }
}

/// Thread-safe handshake state shared between NIO callbacks and the CLI task.
private final class PairingTLSAttemptState: @unchecked Sendable {
    enum Value {
        case notStarted
        case started
        case succeeded
        case failed
    }

    private let lock = NSLock()
    private var storedValue = Value.notStarted

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

/// Returns public certificate metadata while keeping raw bytes out of logs.
private func certificateDiagnostic(
    _ data: Data?
) -> PairingCertificateDiagnostic? {
    guard let data else {
        return nil
    }
    let digest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    let encoding = String(
        data: data.prefix(64),
        encoding: .utf8
    )?.contains("-----BEGIN ") == true ? "pem" : "der"
    return PairingCertificateDiagnostic(
        byteCount: data.count,
        encoding: encoding,
        sha256: digest
    )
}

/// Avoids another Foundation NSError bridge when an unexpected error escapes.
private func pairingDiagnosticErrorDescription(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    return String(reflecting: error)
}

/// Prints the same report shape in a concise terminal-oriented form.
private func printPairingDiagnosticReport(
    _ report: PairingDiagnosticReport
) {
    print("Pairing diagnostics for \(report.deviceIdentifier):")
    for attempt in report.attempts {
        let status = attempt.succeeded ? "passed" : "failed"
        print("- \(attempt.profile): \(status) at \(attempt.phase)")
        if let error = attempt.error {
            print("  \(error)")
        }
    }
}
