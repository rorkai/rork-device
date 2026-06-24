import XCTest

@testable import RorkDeviceWeb

final class WebUSBErrorTests: XCTestCase {
    func testClassifiesDisconnectedDeviceDuringOpen() {
        let error = webUSBError(
            forMethod: "open",
            message:
                "JSException(NotFoundError: Failed to execute 'open' on "
                + "'USBDevice': The device was disconnected.)"
        )

        XCTAssertEqual(error, .deviceUnavailable)
    }

    func testClassifiesInterfaceOwnedByAnotherApplication() {
        let error = webUSBError(
            forMethod: "claimInterface",
            message:
                "JSException(NetworkError: Failed to execute "
                + "'claimInterface' on 'USBDevice': Unable to claim "
                + "interface.)"
        )

        XCTAssertEqual(error, .interfaceInUse)
    }

    func testClassifiesFailedResetAfterOwnershipChanges() {
        let error = webUSBError(
            forMethod: "reset",
            message:
                "JSException(NetworkError: Failed to execute 'reset' on "
                + "'USBDevice': Unable to reset the device.)"
        )

        XCTAssertEqual(error, .deviceUnavailable)
    }

    func testClassifiesResetIndependentlyOfDisplayDescription() {
        let error = webUSBError(
            forMethod: "reset",
            describedAs: "Resetting the USB device",
            message:
                "JSException(NetworkError: Failed to execute 'reset' on "
                + "'USBDevice': Unable to reset the device.)"
        )

        XCTAssertEqual(error, .deviceUnavailable)
    }

    func testPreservesUnrecognizedBrowserFailureDetails() {
        let error = webUSBError(
            forMethod: "selectConfiguration",
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
