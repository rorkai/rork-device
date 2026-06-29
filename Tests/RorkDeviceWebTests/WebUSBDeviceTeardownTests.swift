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

    func testFailedConnectionAfterInterfaceClaimReleasesResetsAndCloses() async {
        enum ExpectedFailure: Error {
            case release
            case reset
        }

        var operations: [String] = []

        await closeFailedWebUSBConnection(
            claimedInterfaceNumber: 3,
            releaseInterface: { interfaceNumber in
                operations.append("release \(interfaceNumber)")
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

        XCTAssertEqual(operations, ["release 3", "reset", "close"])
    }

    func testFailedConnectionBeforeInterfaceClaimOnlyCloses() async {
        var operations: [String] = []

        await closeFailedWebUSBConnection(
            claimedInterfaceNumber: nil,
            releaseInterface: { interfaceNumber in
                operations.append("release \(interfaceNumber)")
            },
            resetDevice: {
                operations.append("reset")
            },
            closeDevice: {
                operations.append("close")
            }
        )

        XCTAssertEqual(operations, ["close"])
    }
}
