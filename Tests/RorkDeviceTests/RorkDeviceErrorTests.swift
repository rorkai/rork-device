import XCTest
@testable import RorkDevice

final class RorkDeviceErrorTests: XCTestCase {
    func testLocalizedDescriptionUsesHumanReadableDescription() {
        let error = RorkDeviceError.installationProxy(
            InstallationError(code: .applicationVerificationFailed, message: "Signature rejected")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "InstallationProxy ApplicationVerificationFailed: Signature rejected"
        )
    }
}
