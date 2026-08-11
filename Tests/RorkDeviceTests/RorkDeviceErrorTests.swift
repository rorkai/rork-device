import XCTest
@testable import RorkDevice

final class RorkDeviceErrorTests: XCTestCase {
    func testLocalizedDescriptionUsesHumanReadableDescription() {
        let error = RorkDeviceError.installationProxy(
            InstallationError(code: .applicationVerificationFailed, message: "Signature rejected")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "InstallationProxy ApplicationVerificationFailed: Signature rejected"
        )
    }

    func testUmbrellaCasesPreserveActionableContext() {
        XCTAssertEqual(
            RorkDeviceError.cancelled.localizedDescription,
            "The operation was cancelled."
        )
        XCTAssertEqual(
            RorkDeviceError.pairing(.deviceLocked).localizedDescription,
            "Unlock the device before pairing."
        )
        XCTAssertEqual(
            RorkDeviceError.fileSystem(
                path: "/tmp/profile.mobileprovision",
                reason: "The file does not exist."
            ).localizedDescription,
            "Local file operation failed for /tmp/profile.mobileprovision: The file does not exist."
        )
    }

    func testNormalizesPairingCancellationAndUnknownFailures() {
        XCTAssertEqual(
            normalizedRorkDeviceError(LockdownPairingError.userDenied),
            .pairing(.userDenied)
        )
        XCTAssertEqual(
            normalizedRorkDeviceError(CancellationError()),
            .cancelled
        )
        XCTAssertEqual(
            normalizedRorkDeviceError(TestFailure.example),
            .transport("example")
        )
    }
}

private enum TestFailure: Error, LocalizedError {
    case example

    var errorDescription: String? {
        "example"
    }
}
