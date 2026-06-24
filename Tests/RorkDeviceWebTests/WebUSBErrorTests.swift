import XCTest

@testable import RorkDeviceWeb

final class WebUSBErrorTests: XCTestCase {
    func testClassifiesDisconnectedDeviceDuringOpen() {
        let error = webUSBError(
            for: "open",
            message:
                "JSException(NotFoundError: Failed to execute 'open' on "
                + "'USBDevice': The device was disconnected.)"
        )

        XCTAssertEqual(error, .deviceUnavailable)
    }

    func testClassifiesInterfaceOwnedByAnotherApplication() {
        let error = webUSBError(
            for: "claimInterface",
            message:
                "JSException(NetworkError: Failed to execute "
                + "'claimInterface' on 'USBDevice': Unable to claim "
                + "interface.)"
        )

        XCTAssertEqual(error, .interfaceInUse)
    }

    func testClassifiesFailedResetAfterOwnershipChanges() {
        let error = webUSBError(
            for: "reset",
            message:
                "JSException(NetworkError: Failed to execute 'reset' on "
                + "'USBDevice': Unable to reset the device.)"
        )

        XCTAssertEqual(error, .deviceUnavailable)
    }

    func testPreservesUnrecognizedBrowserFailureDetails() {
        let error = webUSBError(
            for: "selectConfiguration",
            message: "The selected configuration is unavailable."
        )

        XCTAssertEqual(
            error,
            .browserOperationFailed(
                operation: "selectConfiguration",
                message: "The selected configuration is unavailable."
            )
        )
    }
}
