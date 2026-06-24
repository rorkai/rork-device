import ArgumentParser
import Foundation
import RorkDevice

/// Resolves one cable-attached device for pairing-specific commands.
func selectedUSBDevice(
    from client: DeviceClient,
    matching identifier: String?
) async throws -> Device {
    let devices = try await client.discoverDevices()
        .filter(isUSBDevice)
    let selected = identifier.map { expected in
        devices.first { $0.identifier == expected }
    } ?? devices.first
    guard let selected else {
        throw ValidationError("No matching USB device found.")
    }
    return selected
}

/// Writes pairing phases to stderr so stdout remains command output.
func writePairingProgress(_ progress: DevicePairingProgress) {
    let message: String
    switch progress {
    case .waitingForUserConfirmation:
        message = "Waiting for the iPhone to trust this Mac."
    case .savingPairingRecord:
        message = "Saving the accepted pairing record."
    }
    guard let data = "rorkdevice: \(message)\n".data(
        using: .utf8
    ) else {
        return
    }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// Opens the exact pairing record and USB route visible to later commands.
///
/// Creating a fresh client, rediscovering the attachment, and reloading usbmux
/// storage matches a separate `pairing validate` process without requiring the
/// user to reset the physical cable connection.
func openValidatedSavedPairingSession(
    for deviceIdentifier: String,
    label: String
) async throws -> DeviceSession {
    let client = DeviceClient()
    let device = try await selectedUSBDevice(
        from: client,
        matching: deviceIdentifier
    )
    let pairingRecord = try await client.pairingRecord(
        for: deviceIdentifier
    )
    let session = try await client.connect(
        to: device,
        using: pairingRecord,
        label: label
    )
    let info = try await session.fetchDeviceInfo()
    try validatePairingIdentity(
        info,
        expectedDeviceIdentifier: deviceIdentifier
    )
    return session
}

/// Delays before validating a pairing record that usbmux just saved.
///
/// iOS can accept the Trust prompt before the current attachment publishes the
/// new host state to fresh Lockdown sessions. Reopening the same record across
/// this bounded window avoids making the user reset the cable connection.
let savedPairingActivationAttemptDelays: [Duration] = [
    .zero,
    .milliseconds(500),
    .seconds(1),
    .seconds(2),
    .seconds(4),
    .seconds(8),
]

/// Waits for a newly saved pairing record to authenticate on a fresh session.
///
/// Each attempt must reuse the accepted record. Retrying with new host material
/// would trigger another Trust prompt and lose the state that may still be
/// propagating through usbmux and Lockdown.
///
/// `attemptDelays` contains the wait before each attempt. A leading `.zero`
/// therefore validates immediately before applying the bounded backoff.
func waitForSavedPairingActivation<Value>(
    attemptDelays: [Duration],
    sleep: (Duration) async throws -> Void,
    onRetry: (Error) -> Void,
    attempt: () async throws -> Value
) async throws -> Value {
    guard !attemptDelays.isEmpty else {
        throw RorkDeviceError.invalidInput(
            "Pairing activation requires at least one validation attempt."
        )
    }

    var lastRetryableError: Error?
    for (index, delay) in attemptDelays.enumerated() {
        if delay > .zero {
            try await sleep(delay)
        }

        do {
            return try await attempt()
        } catch {
            guard isRetryablePairingActivationError(error) else {
                throw error
            }
            lastRetryableError = error
            guard index + 1 < attemptDelays.count else {
                break
            }
            onRetry(error)
        }
    }

    throw lastRetryableError ?? RorkDeviceError.invalidInput(
        "Pairing activation ended without a validation result."
    )
}

/// Returns whether a fresh session can reasonably recover without new trust.
private func isRetryablePairingActivationError(_ error: Error) -> Bool {
    guard let error = error as? RorkDeviceError else {
        return false
    }
    switch error {
    case .transport, .lockdown, .secureSession:
        return true
    default:
        return false
    }
}

/// Reports delayed activation while preserving the exact underlying failure.
func writePairingActivationRetry(_ error: Error) {
    guard let data = """
        rorkdevice: The accepted pairing is not active yet; retrying. \
        \(diagnosticDescription(of: error))

        """.data(using: .utf8) else {
        return
    }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// Preserves typed device errors instead of using Foundation's lossy NSError bridge.
func diagnosticDescription(of error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    return String(reflecting: error)
}
