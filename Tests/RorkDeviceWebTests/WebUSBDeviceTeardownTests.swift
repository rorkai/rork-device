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

        let handle = RecordingWebUSBConnectionHandle(
            releaseError: ExpectedFailure.release,
            resetError: ExpectedFailure.reset
        )

        await handle.cleanUpFailedConnection(at: .claimedInterface(3))

        XCTAssertEqual(handle.operations, ["release 3", "reset", "close"])
    }

    func testFailedConnectionBeforeInterfaceClaimOnlyCloses() async {
        let handle = RecordingWebUSBConnectionHandle()

        await handle.cleanUpFailedConnection(at: .opened)

        XCTAssertEqual(handle.operations, ["close"])
    }
}

@MainActor
private final class RecordingWebUSBConnectionHandle: WebUSBConnectionHandle {
    private let releaseError: (any Error)?
    private let resetError: (any Error)?
    private let closeError: (any Error)?

    var operations: [String] = []

    init(
        releaseError: (any Error)? = nil,
        resetError: (any Error)? = nil,
        closeError: (any Error)? = nil
    ) {
        self.releaseError = releaseError
        self.resetError = resetError
        self.closeError = closeError
    }

    func releaseInterface(_ interfaceNumber: UInt8) async throws {
        operations.append("release \(interfaceNumber)")
        if let releaseError {
            throw releaseError
        }
    }

    func reset() async throws {
        operations.append("reset")
        if let resetError {
            throw resetError
        }
    }

    func close() async throws {
        operations.append("close")
        if let closeError {
            throw closeError
        }
    }
}
