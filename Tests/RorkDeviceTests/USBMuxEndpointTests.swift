import XCTest

@testable import RorkDevice

/// Verifies each host family selects the usbmux endpoint it supports.
final class USBMuxEndpointTests: XCTestCase {
    /// Confirms Windows connects to the loopback usbmux TCP listener.
    func testWindowsDefaultUsesLoopbackTCP() {
        XCTAssertEqual(
            USBMuxEndpoint.default(for: .windows),
            .tcp(host: "127.0.0.1", port: 27_015)
        )
    }

    /// Confirms POSIX hosts connect through the daemon's Unix socket.
    func testPOSIXDefaultUsesDaemonSocket() {
        XCTAssertEqual(
            USBMuxEndpoint.default(for: .posix),
            .unixSocket(path: "/var/run/usbmuxd")
        )
    }
}
