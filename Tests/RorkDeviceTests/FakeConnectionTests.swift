import Foundation
import XCTest
@testable import RorkDevice

final class FakeConnectionTests: XCTestCase {
    func testCloseRejectsLaterIO() async throws {
        let connection = FakeConnection(inbound: Data([1, 2, 3, 4]))

        connection.close()

        await XCTAssertThrowsErrorAsync({
            try await connection.send(Data([5]))
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .transport("Fake connection is closed."))
        }
        await XCTAssertThrowsErrorAsync({
            _ = try await connection.receive(count: 1)
        }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .transport("Fake connection is closed."))
        }
    }
}
