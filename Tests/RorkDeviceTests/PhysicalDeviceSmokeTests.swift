import Foundation
import XCTest
@testable import RorkDevice

/// Opt-in smoke tests against a real paired iOS device.
///
/// These tests intentionally do not run during normal CI. They exercise the
/// release-critical vertical slice through the public API: device discovery,
/// Lockdown info, provisioning-profile installation, IPA installation, and IPA
/// uninstall.
final class PhysicalDeviceSmokeTests: XCTestCase {
    /// Lists a physical device, opens a secure session, installs a profile,
    /// installs an IPA, and uninstalls the same bundle identifier.
    func testPhysicalDeviceInstallWorkflow() async throws {
        guard ProcessInfo.processInfo.environment["RORK_DEVICE_PHYSICAL_SMOKE"] == "1" else {
            throw XCTSkip("Set RORK_DEVICE_PHYSICAL_SMOKE=1 to run physical-device smoke tests.")
        }

        let pairingRecordURL = try requiredEnvironmentURL("RORK_DEVICE_PAIRING_RECORD")
        let provisioningProfileURL = try requiredEnvironmentURL("RORK_DEVICE_PROFILE")
        let ipaURL = try requiredEnvironmentURL("RORK_DEVICE_IPA")
        let bundleIdentifier = try requiredEnvironment("RORK_DEVICE_BUNDLE_ID")
        let requestedUDID = ProcessInfo.processInfo.environment["RORK_DEVICE_UDID"]

        let client = DeviceClient()
        let devices = try await client.devices()
        let device = try selectDevice(from: devices, requestedUDID: requestedUDID)
        let pairingRecord = try PairingRecord.load(from: pairingRecordURL)
        let session = try await client.session(for: device, pairingRecord: pairingRecord)

        _ = try await session.deviceInfo()
        try await session.installProvisioningProfile(at: provisioningProfileURL)
        try await session.installApplication(ipaURL: ipaURL, bundleIdentifier: bundleIdentifier)
        try await session.uninstallApplication(bundleIdentifier: bundleIdentifier)
    }
}

/// Reads a required environment variable for physical smoke configuration.
private func requiredEnvironment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        throw RorkDeviceError.invalidInput("Missing \(name) for physical-device smoke test.")
    }
    return value
}

/// Reads a required environment variable as a file URL.
private func requiredEnvironmentURL(_ name: String) throws -> URL {
    URL(fileURLWithPath: try requiredEnvironment(name))
}

/// Selects the requested device or the single visible device.
private func selectDevice(from devices: [Device], requestedUDID: String?) throws -> Device {
    if let requestedUDID, !requestedUDID.isEmpty {
        guard let device = devices.first(where: { $0.identifier == requestedUDID }) else {
            throw RorkDeviceError.invalidInput("No visible device matched RORK_DEVICE_UDID.")
        }
        return device
    }

    guard !devices.isEmpty else {
        throw RorkDeviceError.invalidInput("No physical iOS device is visible through usbmux.")
    }
    guard devices.count == 1, let device = devices.first else {
        throw RorkDeviceError.invalidInput("Multiple devices are visible; set RORK_DEVICE_UDID.")
    }
    return device
}
