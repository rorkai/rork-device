import XCTest

@testable import RorkDeviceWeb

final class WebUSBInterfaceClaimTests: XCTestCase {
    @MainActor
    func testRecoversAndRetriesOneFailedBrowserClaim() async throws {
        var claimAttempts = 0
        var recoveryAttempts = 0

        try await claimWebUSBInterface(
            using: {
                claimAttempts += 1
                if claimAttempts == 1 {
                    throw WebUSBError.browserOperationFailed(
                        operation: "claimInterface",
                        message: "The interface is still owned by a prior page."
                    )
                }
            },
            recoveringWith: {
                recoveryAttempts += 1
            }
        )

        XCTAssertEqual(claimAttempts, 2)
        XCTAssertEqual(recoveryAttempts, 1)
    }

    @MainActor
    func testDoesNotRecoverAnUnrelatedBrowserFailure() async {
        var claimAttempts = 0
        var recoveryAttempts = 0

        do {
            try await claimWebUSBInterface(
                using: {
                    claimAttempts += 1
                    throw WebUSBError.browserOperationFailed(
                        operation: "selectConfiguration",
                        message: "The configuration is unavailable."
                    )
                },
                recoveringWith: {
                    recoveryAttempts += 1
                }
            )
            XCTFail("Expected the original browser failure.")
        } catch {
            XCTAssertEqual(
                error as? WebUSBError,
                .browserOperationFailed(
                    operation: "selectConfiguration",
                    message: "The configuration is unavailable."
                )
            )
        }

        XCTAssertEqual(claimAttempts, 1)
        XCTAssertEqual(recoveryAttempts, 0)
    }
}
