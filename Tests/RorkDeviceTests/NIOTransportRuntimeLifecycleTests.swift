import Foundation
import NIOCore
import XCTest

@testable import RorkDevice

/// Verifies the shared runtime is safe to use and shuts down after the suite.
final class NIOTransportRuntimeLifecycleTests: XCTestCase {
    /// Bundle observer that owns the one permitted runtime shutdown.
    private static let runtimeShutdownObserver =
        NIOTransportRuntimeShutdownObserver()

    /// Registers runtime teardown before this test class executes.
    override class func setUp() {
        super.setUp()
        XCTestObservationCenter.shared.addTestObserver(
            runtimeShutdownObserver
        )
    }

    /// Confirms callers are not already executing on the shared event loop.
    func testSharedRuntimeUsesBackgroundEventLoop() {
        XCTAssertFalse(
            NIOTransportRuntime.eventLoopGroup.next().inEventLoop
        )
    }
}

/// Stops the package-wide event loop after XCTest has finished every test.
///
/// Windows keeps native event-loop threads alive until they are explicitly
/// joined. XCTest invokes this observer outside the event-loop group, so the
/// synchronous shutdown can finish before the test process exits.
private final class NIOTransportRuntimeShutdownObserver:
    NSObject,
    XCTestObservation,
    @unchecked Sendable
{
    /// Joins the shared event-loop threads after the complete test bundle ends.
    func testBundleDidFinish(_: Bundle) {
        precondition(
            !NIOTransportRuntime.eventLoopGroup.next().inEventLoop,
            "XCTest must not shut down the shared runtime from its event loop."
        )
        do {
            try NIOTransportRuntime.eventLoopGroup
                .syncShutdownGracefully()
        } catch {
            fatalError(
                "Failed to stop the shared event-loop runtime: \(error)"
            )
        }
    }
}
