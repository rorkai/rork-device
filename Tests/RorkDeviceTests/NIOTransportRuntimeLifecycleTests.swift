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

/**
 * Stops the package-wide event loop after XCTest has finished every test.
 *
 * Windows keeps native event-loop threads alive until they are explicitly
 * joined, so the test process cannot terminate while the shared runtime runs.
 * The observer has no mutable state, so callbacks may cross test executors.
 */
private final class NIOTransportRuntimeShutdownObserver:
    NSObject,
    XCTestObservation,
    @unchecked Sendable
{
    func testBundleDidFinish(_ testBundle: Bundle) {
        do {
            try NIOTransportRuntime.eventLoopGroup
                .syncShutdownGracefully()
        } catch {
            XCTFail("Failed to stop the shared event-loop runtime: \(error)")
        }
    }
}
