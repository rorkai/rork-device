import Foundation
import XCTest

@testable import RorkDeviceWeb

final class WebUSBHostIdentifierTests: XCTestCase {
    func testGeneratesPersistentIdentifierValue() throws {
        let identifier = WebUSBHostIdentifier()

        XCTAssertNotNil(UUID(uuidString: identifier.rawValue))
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebUSBHostIdentifier.self,
                from: JSONEncoder().encode(identifier)
            ),
            identifier
        )
    }

    func testNormalizesPersistedIdentifier() throws {
        let identifier = try XCTUnwrap(
            WebUSBHostIdentifier(rawValue: "  browser-installation-1\n")
        )

        XCTAssertEqual(identifier.rawValue, "browser-installation-1")
    }

    func testRejectsEmptyIdentifier() {
        XCTAssertNil(WebUSBHostIdentifier(rawValue: " \n\t"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WebUSBHostIdentifier.self,
                from: Data(#"" \n ""#.utf8)
            )
        )
    }
}
