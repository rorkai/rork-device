import XCTest

@testable import RorkDevice

final class USBMuxEndpointTests: XCTestCase {
    func testWindowsDefaultUsesLoopbackTCP() {
        XCTAssertEqual(
            USBMuxEndpoint.default(for: .windows),
            .tcp(host: "127.0.0.1", port: 27_015)
        )
    }

    func testPOSIXDefaultUsesDaemonSocket() {
        XCTAssertEqual(
            USBMuxEndpoint.default(for: .posix),
            .unixSocket(path: "/var/run/usbmuxd")
        )
    }
}
