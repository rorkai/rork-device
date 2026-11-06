import ArgumentParser
import Foundation
import RorkDevice

/// Opt-in machine-readable failure output for processes that supervise the CLI.
///
/// When `RORKDEVICE_FAILURE_FORMAT=json` is set and a command exits with a
/// non-zero status, the CLI prints its usual human-readable error and then one
/// final standard-error line holding `{"failure": {...}}`, where the object is
/// an encoded ``RorkDeviceFailure``. Without the variable the output is
/// unchanged.
enum FailureReport {
    /// Environment variable that selects the failure output format.
    static let formatVariable = "RORKDEVICE_FAILURE_FORMAT"

    /// Whether the environment asks for the JSON failure line.
    static func isEnabled(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[formatVariable] == "json"
    }

    /// A failure the command already reported in its own output, such as a
    /// diagnostic report.
    ///
    /// Throwing it exits with status 1 without printing the error again,
    /// while the opt-in failure line still classifies `underlying`.
    struct AlreadyReported: Error {
        /// The error the command reported.
        let underlying: Error
    }

    /// Where a command failed, which decides how its error classifies.
    enum Phase {
        /// Parsing or validating the command line.
        case parsing

        /// Running the parsed command.
        case running
    }

    /// Classifies a command failure, including argument-parsing errors that
    /// the library does not know about.
    ///
    /// Everything that fails while parsing is invalid input, whatever its
    /// type. ArgumentParser wraps an error a `validate()` method throws in
    /// its own internal type, so a library `invalidInput` from validation
    /// cannot be recognized by type after parsing.
    static func failure(for error: Error, phase: Phase = .running) -> RorkDeviceFailure {
        if phase == .parsing {
            return RorkDeviceFailure(
                code: .invalidInput,
                message: RorkDeviceCommand.message(for: error)
            )
        }
        if let reported = error as? AlreadyReported {
            return failure(for: reported.underlying)
        }
        if error is any RorkDeviceFailureConvertible || error is CancellationError {
            return RorkDeviceFailure(error)
        }
        let exitCode = RorkDeviceCommand.exitCode(for: error)
        if exitCode == .validationFailure {
            return RorkDeviceFailure(
                code: .invalidInput,
                message: RorkDeviceCommand.message(for: error)
            )
        }
        if error is ExitCode {
            // The command already reported the failure in its own output
            // and left only the status behind.
            return RorkDeviceFailure(
                code: .unknown,
                message: "The command failed with exit code \(exitCode.rawValue)."
            )
        }
        return RorkDeviceFailure(
            code: .unknown,
            message: RorkDeviceCommand.message(for: error)
        )
    }

    /// What a failed run writes to standard error and its exit status, or
    /// nil when ArgumentParser's own `exit(withError:)` handles the error
    /// unchanged: the format is not requested, or the error is a clean exit
    /// such as `--help`. An ``AlreadyReported`` failure always terminates
    /// here, because ArgumentParser would print it again.
    static func termination(
        for error: Error,
        phase: Phase,
        environment: [String: String]
    ) -> (standardError: Data, status: Int32)? {
        if error is AlreadyReported {
            guard isEnabled(in: environment),
                let line = try? line(for: failure(for: error, phase: phase))
            else {
                return (Data(), ExitCode.failure.rawValue)
            }
            return (line + Data([0x0a]), ExitCode.failure.rawValue)
        }
        let exitCode = RorkDeviceCommand.exitCode(for: error)
        guard exitCode != .success, isEnabled(in: environment) else {
            return nil
        }
        var output = Data()
        let message = RorkDeviceCommand.fullMessage(for: error)
        if !message.isEmpty {
            output.append(Data((message + "\n").utf8))
        }
        if let line = try? line(for: failure(for: error, phase: phase)) {
            output.append(line)
            output.append(0x0a)
        }
        return (output, exitCode.rawValue)
    }

    /// Encodes the final standard-error line, without its newline.
    static func line(for failure: RorkDeviceFailure) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Line(failure: failure))
    }

    /// Wraps the failure under one key, so a reader can tell the line apart
    /// from any other JSON a command prints.
    private struct Line: Encodable {
        let failure: RorkDeviceFailure
    }
}

extension RorkDeviceCommand {
    /// Runs the selected command, reporting failures through
    /// ``exit(reporting:phase:environment:)``.
    static func main() async {
        var command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exit(reporting: error, phase: .parsing)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(reporting: error, phase: .running)
        }
    }

    /// Exits like `exit(withError:)`, appending the JSON failure line when
    /// the environment asks for it and the status is a failure.
    static func exit(
        reporting error: Error,
        phase: FailureReport.Phase,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Never {
        guard let termination = FailureReport.termination(
            for: error,
            phase: phase,
            environment: environment
        ) else {
            exit(withError: error)
        }
        try? FileHandle.standardError.write(contentsOf: termination.standardError)
        Foundation.exit(termination.status)
    }
}
