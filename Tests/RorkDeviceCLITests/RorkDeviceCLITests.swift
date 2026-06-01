import XCTest
@testable import RorkDeviceCLI

final class RorkDeviceCLITests: XCTestCase {
    func testHelpMentionsCoreCommands() {
        let help = RorkDeviceCommand.helpMessage()

        XCTAssertTrue(help.contains("rorkdevice"))
        XCTAssertTrue(help.contains("list"))
        XCTAssertTrue(help.contains("install"))
        XCTAssertTrue(help.contains("profiles"))
    }
}
