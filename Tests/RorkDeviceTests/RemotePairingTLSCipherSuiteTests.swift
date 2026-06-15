import XCTest
@testable import RorkDevice

final class RemotePairingTLSCipherSuiteTests: XCTestCase {
    func testKnownCipherSuiteProvidesItsIANANameAndDescription() {
        let cipherSuite = RemotePairingTLSCipherSuite(rawValue: 0x00AF)

        XCTAssertEqual(
            cipherSuite.ianaName,
            "TLS_PSK_WITH_AES_256_CBC_SHA384"
        )
        XCTAssertEqual(
            cipherSuite.description,
            "TLS_PSK_WITH_AES_256_CBC_SHA384 (0x00AF)"
        )
    }

    func testUnknownCipherSuitePreservesItsWireValue() {
        let cipherSuite = RemotePairingTLSCipherSuite(rawValue: 0x1234)

        XCTAssertNil(cipherSuite.ianaName)
        XCTAssertEqual(
            cipherSuite.description,
            "unknown TLS cipher suite (0x1234)"
        )
    }
}
