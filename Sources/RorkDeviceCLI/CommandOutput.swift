import Foundation

/// Routes a command's output either to standard output or to the serving
/// agent's per-request capture.
///
/// Commands run in their own process almost always, and there the functions
/// below write to standard output exactly as before. When the tunnel agent
/// runs a command in-process for the `run` operation, it binds `sink` for
/// the duration of that request, so the command's output becomes the reply
/// payload instead of interleaving with the agent's machine-readable stdout.
/// The binding is a task local, which scopes it to one request even while
/// other requests run concurrently.
enum CommandOutput {
    /// Receives the running command's output while bound, replacing
    /// standard output.
    @TaskLocal static var sink: (@Sendable (Data) -> Void)?

    /// Writes raw bytes to the command's output.
    ///
    /// The label matches `FileHandle.write(contentsOf:)`, which keeps the
    /// call sites in command bodies textually identical to what they
    /// replaced.
    static func write(contentsOf data: Data) throws {
        if let sink {
            sink(data)
            return
        }
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    /// Writes one item and a newline to the command's output, matching the
    /// single-argument shape of `Swift.print`.
    static func print(_ item: Any) {
        if let sink {
            sink(Data((String(describing: item) + "\n").utf8))
            return
        }
        Swift.print(item)
    }
}
