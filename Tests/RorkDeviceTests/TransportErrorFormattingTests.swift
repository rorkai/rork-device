import NIOCore
import NIOSSL
import XCTest
@testable import RorkDevice

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

final class TransportErrorFormattingTests: XCTestCase {
    #if os(Windows)
    func testWinsockErrorPreservesSystemDescriptionWithoutReadingErrno() {
        let error = NIOCore.IOError(
            winsock: WSAECONNREFUSED,
            reason: "connect"
        )

        let description = describeTransportError(error)

        XCTAssertTrue(description.contains("SwiftNIO IOError"))
        XCTAssertTrue(description.contains(error.description))
    }

    func testRecognizesWinsockAddressInUse() {
        XCTAssertTrue(
            isAddressInUseError(
                NIOCore.IOError(
                    winsock: WSAEADDRINUSE,
                    reason: "bind"
                )
            )
        )
        XCTAssertFalse(
            isAddressInUseError(
                NIOCore.IOError(
                    winsock: WSAECONNREFUSED,
                    reason: "bind"
                )
            )
        )
    }
    #else
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

    func testRecognizesPOSIXAddressInUse() {
        XCTAssertTrue(
            isAddressInUseError(
                NIOCore.IOError(
                    errnoCode: EADDRINUSE,
                    reason: "bind"
                )
            )
        )
        XCTAssertFalse(
            isAddressInUseError(
                NIOCore.IOError(
                    errnoCode: ECONNREFUSED,
                    reason: "bind"
                )
            )
        )
    }
    #endif

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
