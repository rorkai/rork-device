import Foundation

/// Suspends until a file handle reaches end-of-file.
///
/// Supervised agent processes use this on standard input: a supervisor that
/// holds the write end of the pipe closes it when it exits — cleanly or by
/// crashing — so end-of-file is a reliable "parent is gone" signal that needs
/// no signal handling or polling. Detection rides on
/// `FileHandle.readabilityHandler`, so no thread is parked on a blocking read.
public enum EndOfFileWatch {
    /// Waits until `fileHandle` reports end-of-file, draining any data first.
    ///
    /// Data arriving on the handle is read and discarded — only the closed
    /// write end resolves the wait. Returns immediately when the handle is
    /// already at end-of-file.
    public static func waitUntilEndOfFile(of fileHandle: FileHandle) async {
        let state = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fileHandle.readabilityHandler = { handle in
                // A readable handle with no available data is at end-of-file.
                guard handle.availableData.isEmpty else {
                    return
                }
                handle.readabilityHandler = nil
                state.resume(continuation)
            }
        }
    }
}

/// Guards a continuation against the readability handler firing repeatedly.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResume: Bool = lock.withLock {
            guard !resumed else {
                return false
            }
            resumed = true
            return true
        }
        if shouldResume {
            continuation.resume()
        }
    }
}
