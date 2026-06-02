import Foundation
import XCTest
@testable import RorkDevice

/// Tests for the platform default secure-session selection.
final class SecureSessionUpgraderTests: XCTestCase {
    /// Verifies that the default upgrader uses the built-in Apple backend when
    /// Security.framework is available.
    func testDefaultUpgraderUsesAppleBackendWhenAvailable() async throws {
        let pairingRecord = try PairingRecord.parse(
            PropertyListSerialization.data(
                fromPropertyList: [
                    "UDID": "device-1",
                    "HostID": "host-1",
                    "SystemBUID": "system-1",
                ],
                format: .xml,
                options: 0
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await DefaultSecureSessionUpgrader().upgrade(
                FakeConnection(),
                pairingRecord: pairingRecord
            )
        }) { error in
            #if canImport(Security)
            XCTAssertEqual(error as? RorkDeviceError, .invalidPairingRecord("Missing DeviceCertificate."))
            #else
            XCTAssertEqual(error as? RorkDeviceError, .secureSessionUnsupported)
            #endif
        }
    }
}
