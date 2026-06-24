import XCTest

@testable import RorkDeviceWeb

@MainActor
final class WebUSBDeviceTeardownTests: XCTestCase {
    func testRunsEveryCleanupStepInHostHandoffOrder() async {
        enum ExpectedFailure: Error {
            case release
            case reset
        }

        var operations: [String] = []

        await closeWebUSBDevice(
            releaseInterface: {
                operations.append("release")
                throw ExpectedFailure.release
            },
            resetDevice: {
                operations.append("reset")
                throw ExpectedFailure.reset
            },
            closeDevice: {
                operations.append("close")
            }
        )

        XCTAssertEqual(operations, ["release", "reset", "close"])
    }
}
