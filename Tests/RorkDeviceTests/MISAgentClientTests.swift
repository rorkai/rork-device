import Foundation
import XCTest
@testable import RorkDevice

final class MISAgentClientTests: XCTestCase {
    func testInstallProvisioningProfileSendsProfilePayload() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": 0])
        let connection = FakeConnection(inbound: inbound)
        let client = MISAgentClient(connection: connection)
        let profile = Data([1, 2, 3])

        try await client.installProvisioningProfile(profile)

        let request = try XCTUnwrap(decodedMessage(connection.sent[0]))
        XCTAssertEqual(request["MessageType"] as? String, "Install")
        XCTAssertEqual(request["ProfileType"] as? String, "Provisioning")
        XCTAssertEqual(request["Profile"] as? Data, profile)
    }

    func testRemoveProvisioningProfileSendsProfileIdentifier() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": 0])
        let connection = FakeConnection(inbound: inbound)
        let client = MISAgentClient(connection: connection)

        try await client.removeProvisioningProfile(identifier: "profile-uuid")

        let request = try XCTUnwrap(decodedMessage(connection.sent[0]))
        XCTAssertEqual(request["MessageType"] as? String, "Remove")
        XCTAssertEqual(request["ProfileID"] as? String, "profile-uuid")
        XCTAssertEqual(request["ProfileType"] as? String, "Provisioning")
    }

    func testNonZeroStatusThrows() async throws {
        let inbound = try PropertyListMessageFramer.encode(["Status": 3892346897])
        let connection = FakeConnection(inbound: inbound)
        let client = MISAgentClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.installProvisioningProfile(Data()) }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .misagentStatus(3892346897))
        }
    }
}

private func decodedMessage(_ data: Data) throws -> [String: Any]? {
    let payload = data.dropFirst(4)
    return try PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil) as? [String: Any]
}
