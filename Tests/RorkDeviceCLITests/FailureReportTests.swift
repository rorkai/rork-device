import ArgumentParser
import Foundation
import RorkDevice
import XCTest
@testable import RorkDeviceCLI

/// Pins the opt-in JSON failure line that supervising processes read from
/// standard error.
final class FailureReportTests: XCTestCase {
    func testIsEnabledOnlyForTheJSONFormat() {
        XCTAssertTrue(FailureReport.isEnabled(in: ["RORKDEVICE_FAILURE_FORMAT": "json"]))
        XCTAssertFalse(FailureReport.isEnabled(in: [:]))
        XCTAssertFalse(FailureReport.isEnabled(in: ["RORKDEVICE_FAILURE_FORMAT": "text"]))
    }

    func testEncodesOneLineUnderTheFailureKey() throws {
        let line = try FailureReport.line(
            for: FailureReport.failure(
                for: RorkDeviceError.deviceNotFound(identifier: "PHONE-1", usbOnly: false)
            )
        )

        XCTAssertEqual(
            String(decoding: line, as: UTF8.self),
            #"{"failure":{"code":"device-not-found","details":{"deviceIdentifier":"PHONE-1"},"message":"No matching device found."}}"#
        )
    }

    /// Argument and option errors never reach the library, so the CLI
    /// classifies them itself.
    func testCommandLineErrorsAreInvalidInput() {
        XCTAssertEqual(
            FailureReport.failure(for: ValidationError("--port requires --host.")),
            RorkDeviceFailure(code: .invalidInput, message: "--port requires --host.")
        )

        do {
            _ = try RorkDeviceCommand.parseAsRoot(["info", "--no-such-option"])
            XCTFail("Expected a parse error")
        } catch {
            XCTAssertEqual(FailureReport.failure(for: error).code, .invalidInput)
        }
    }

    func testLibraryErrorsKeepTheirClassification() {
        XCTAssertEqual(
            FailureReport.failure(for: RorkDeviceError.remotePairing(.unknownPeer)).code,
            .trustNotRecognized
        )
        XCTAssertEqual(
            FailureReport.failure(for: LockdownPairingError.deviceLocked).code,
            .deviceLocked
        )
    }

    /// A command that printed its own report and exited with a bare status
    /// still ends with a failure line, so readers can rely on its presence.
    func testABareExitCodeIsUnknown() {
        XCTAssertEqual(
            FailureReport.failure(for: ExitCode.failure),
            RorkDeviceFailure(
                code: .unknown,
                message: "The command failed with exit code 1."
            )
        )
    }
}
