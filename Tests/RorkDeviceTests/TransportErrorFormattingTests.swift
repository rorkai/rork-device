import Darwin
import NIOCore
import XCTest
@testable import RorkDevice

final class TransportErrorFormattingTests: XCTestCase {
    func testSwiftNIOErrorPreservesErrnoAndOperation() {
        let error: Error = NIOCore.IOError(
            errnoCode: ECONNREFUSED,
            reason: "connect"
        )

        let description = describeTransportError(error)

        XCTAssertTrue(description.contains("SwiftNIO IOError errno=\(ECONNREFUSED)"))
        XCTAssertTrue(description.contains("connect"))
        XCTAssertTrue(description.contains(String(cString: strerror(ECONNREFUSED))))
        XCTAssertFalse(description.contains("NIOCore.IOError error 1"))
    }
}
