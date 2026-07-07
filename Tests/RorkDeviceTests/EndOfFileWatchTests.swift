import Foundation
import XCTest

@testable import RorkDevice

/// End-of-file detection used by supervised tunnel agents to exit when their
/// parent process dies and the inherited stdin pipe closes.
final class EndOfFileWatchTests: XCTestCase {
    func testResumesWhenTheWriteEndCloses() async throws {
        let pipe = Pipe()

        let waiter = Task {
            await EndOfFileWatch.waitUntilEndOfFile(of: pipe.fileHandleForReading)
            return true
        }
        try pipe.fileHandleForWriting.close()

        let reachedEndOfFile = await waiter.value
        XCTAssertTrue(reachedEndOfFile)
    }

    func testPendingDataDoesNotEndTheWait() async throws {
        let pipe = Pipe()
        let finished = ObservedFlag()

        let waiter = Task {
            await EndOfFileWatch.waitUntilEndOfFile(of: pipe.fileHandleForReading)
            finished.set()
        }
        // Data on the handle must be drained, not treated as end-of-file.
        try pipe.fileHandleForWriting.write(contentsOf: Data("keepalive".utf8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished.isSet)

        try pipe.fileHandleForWriting.close()
        await waiter.value
        XCTAssertTrue(finished.isSet)
    }

    func testAnAlreadyClosedHandleResolvesImmediately() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        // Must not hang: end-of-file is already the handle's terminal state.
        await EndOfFileWatch.waitUntilEndOfFile(of: pipe.fileHandleForReading)
    }
}

/// Minimal thread-safe boolean for asserting ordering across tasks.
private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
