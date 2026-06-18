import Foundation
import XCTest

@testable import RorkDevice

final class DeveloperModeClientTests: XCTestCase {
    func testRevealSendsAMFIActionZero() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "success": true
            ])
        )
        let client = DeveloperModeClient(connection: connection)

        try await client.reveal()

        let request = try decodedPropertyListMessage(connection.sent[0])
        XCTAssertEqual(request["action"] as? Int, 0)
    }

    func testRevealPropagatesDeviceError() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": "DeviceLocked"
            ])
        )
        let client = DeveloperModeClient(connection: connection)

        await XCTAssertThrowsErrorAsync(
            {
                try await client.reveal()
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .lockdown(
                        "Developer Mode reveal failed: DeviceLocked"
                    )
                )
            }
        )
    }

    func testRevealRejectsResponseWithoutResult() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Status": "Unknown"
            ])
        )
        let client = DeveloperModeClient(connection: connection)

        await XCTAssertThrowsErrorAsync(
            {
                try await client.reveal()
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .protocolViolation(
                        "Developer Mode reveal response did not report success."
                    )
                )
            }
        )
    }

    func testRevealRejectsUnsuccessfulResult() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "success": false
            ])
        )
        let client = DeveloperModeClient(connection: connection)

        await XCTAssertThrowsErrorAsync(
            {
                try await client.reveal()
            },
            { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .protocolViolation(
                        "Developer Mode reveal response did not report success."
                    )
                )
            }
        )
    }
}

/// Decodes one length-prefixed property-list message captured by a fake stream.
private func decodedPropertyListMessage(
    _ data: Data
) throws -> [String: Any] {
    let payload = data.dropFirst(4)
    return try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: Data(payload),
            options: [],
            format: nil
        ) as? [String: Any]
    )
}
