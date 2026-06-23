import NIOCore
import NIOSSL
import XCTest
@testable import RorkDevice

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    func testNIOSSLHandshakeErrorPreservesBoringSSLDetails() {
        let error: Error = NIOSSLError.handshakeFailed(
            .sslError([])
        )

        let description = describeTransportError(error)

        XCTAssertTrue(description.contains("handshakeFailed"))
        XCTAssertTrue(description.contains("sslError"))
        XCTAssertFalse(description.contains("NIOSSL.NIOSSLError error 0"))
    }
}
