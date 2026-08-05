import Foundation
import NIOCore
import XCTest

@testable import RorkDevice

final class NIOTransportRuntimeLifecycleTests: XCTestCase {
    private static let runtimeShutdownObserver =
        NIOTransportRuntimeShutdownObserver()

    override class func setUp() {
        super.setUp()
        XCTestObservationCenter.shared.addTestObserver(
            runtimeShutdownObserver
        )
    }

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
