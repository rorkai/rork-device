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
            XCTAssertEqual(
                FailureReport.failure(for: error, phase: .parsing).code,
                .invalidInput
            )
        }
    }

    /// ArgumentParser wraps a library error thrown from `validate()` in an
    /// internal type, which must still classify as invalid input with the
    /// rendered message rather than the wrapper's description.
    func testLibraryErrorsFromValidationAreInvalidInput() {
        do {
            _ = try RorkDeviceCommand.parseAsRoot([
                "image", "auto",
                "--archive-url", "http://example.invalid/image.zip",
                "--sha256", "abc",
            ])
            XCTFail("Expected a validation error")
        } catch {
            let failure = FailureReport.failure(for: error, phase: .parsing)
            XCTAssertEqual(failure.code, .invalidInput)
            XCTAssertEqual(failure.message, RorkDeviceCommand.message(for: error))
            XCTAssertFalse(failure.message.contains("CommandError"))
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

    private static let jsonEnvironment = ["RORKDEVICE_FAILURE_FORMAT": "json"]

    /// Splits rendered standard error into its lines.
    private func lines(of data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testAParseFailureKeepsUsageAndEndsWithTheFailureLine() throws {
        var parseError: Error?
        do {
            _ = try RorkDeviceCommand.parseAsRoot(["info", "--port", "5"])
        } catch {
            parseError = error
        }
        let error = try XCTUnwrap(parseError)

        let termination = try XCTUnwrap(
            FailureReport.termination(for: error, phase: .parsing, environment: Self.jsonEnvironment)
        )

        XCTAssertEqual(termination.status, ExitCode.validationFailure.rawValue)
        let output = lines(of: termination.standardError)
        XCTAssertEqual(output.first, "Error: --port requires --host.")
        XCTAssertTrue(output.contains { $0.hasPrefix("Usage: rorkdevice info") })
        XCTAssertEqual(
            output.last,
            #"{"failure":{"code":"invalid-input","message":"--port requires --host."}}"#
        )
    }

    func testARunFailureExitsOneWithTheTypedLine() throws {
        let termination = try XCTUnwrap(
            FailureReport.termination(
                for: RorkDeviceError.deviceNotFound(identifier: nil, usbOnly: false),
                phase: .running,
                environment: Self.jsonEnvironment
            )
        )

        XCTAssertEqual(termination.status, 1)
        XCTAssertEqual(
            lines(of: termination.standardError),
            [
                "Error: No matching device found.",
                #"{"failure":{"code":"device-not-found","message":"No matching device found."}}"#,
            ]
        )
    }

    /// `remote-pairing diagnose` prints its report and throws a bare
    /// status; the line still ends its output.
    func testABareExitCodeStillEndsWithTheFailureLine() throws {
        let termination = try XCTUnwrap(
            FailureReport.termination(
                for: ExitCode.failure,
                phase: .running,
                environment: Self.jsonEnvironment
            )
        )

        XCTAssertEqual(termination.status, 1)
        XCTAssertEqual(
            lines(of: termination.standardError),
            [#"{"failure":{"code":"unknown","message":"The command failed with exit code 1."}}"#]
        )
    }

    func testDefersToArgumentParserWhenNotRequestedOrClean() {
        XCTAssertNil(
            FailureReport.termination(
                for: RorkDeviceError.connectionClosed("Connection closed."),
                phase: .running,
                environment: [:]
            )
        )
        XCTAssertNil(
            FailureReport.termination(
                for: CleanExit.helpRequest(),
                phase: .parsing,
                environment: Self.jsonEnvironment
            )
        )
    }

    /// `remote-pairing diagnose` prints its own report, so it exits quietly
    /// without the line and keeps the typed classification with it.
    func testAnAlreadyReportedFailureKeepsItsClassification() throws {
        let error = FailureReport.AlreadyReported(
            underlying: RorkDeviceError.remotePairing(.unknownPeer)
        )

        let quiet = try XCTUnwrap(
            FailureReport.termination(for: error, phase: .running, environment: [:])
        )
        XCTAssertEqual(quiet.status, 1)
        XCTAssertTrue(quiet.standardError.isEmpty)

        let reported = try XCTUnwrap(
            FailureReport.termination(for: error, phase: .running, environment: Self.jsonEnvironment)
        )
        XCTAssertEqual(reported.status, 1)
        XCTAssertEqual(
            lines(of: reported.standardError),
            [#"{"failure":{"code":"trust-not-recognized","message":"The device does not recognize this remote-pairing identity."}}"#]
        )
    }
}
