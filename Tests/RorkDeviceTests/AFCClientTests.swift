import Foundation
import XCTest
@testable import RorkDevice

final class AFCClientTests: XCTestCase {
    func testMakeDirectorySendsPathOperation() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 0))
        let client = AFCClient(connection: connection)

        try await client.makeDirectory("/PublicStaging")

        XCTAssertEqual(connection.sent.count, 1)
        XCTAssertEqual(try afcOperation(connection.sent[0]), 9)
        XCTAssertTrue(connection.sent[0].contains(Data("/PublicStaging".utf8)))
    }

    func testRemovePathCanIgnoreNonZeroStatus() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 8))
        let client = AFCClient(connection: connection)

        try await client.removePath("/missing", ignoreMissing: true)

        XCTAssertEqual(connection.sent.count, 1)
        XCTAssertEqual(try afcOperation(connection.sent[0]), 8)
    }

    func testUploadFileOpensWritesAndClosesRemoteFile() async throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var inbound = Data()
        inbound.append(afcFileOpenResponse(packetNumber: 1, handle: 99))
        inbound.append(afcStatusResponse(packetNumber: 2, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 3, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        try await client.uploadFile(localURL: fileURL, remotePath: "/PublicStaging/App.ipa")

        XCTAssertEqual(connection.sent.count, 3)
        XCTAssertEqual(try connection.sent.map(afcOperation), [13, 16, 20])
        XCTAssertTrue(connection.sent[1].contains(Data("hello".utf8)))
    }
}

private func afcOperation(_ packet: Data) throws -> UInt64 {
    try packet.littleEndianInteger(at: 32, as: UInt64.self)
}

private func afcStatusResponse(packetNumber: UInt64, status: UInt64) -> Data {
    var payload = Data()
    payload.appendLittleEndian(status)
    return afcResponse(packetNumber: packetNumber, operation: 1, payload: payload)
}

private func afcFileOpenResponse(packetNumber: UInt64, handle: UInt64) -> Data {
    var payload = Data()
    payload.appendLittleEndian(handle)
    return afcResponse(packetNumber: packetNumber, operation: 14, payload: payload)
}

private func afcResponse(packetNumber: UInt64, operation: UInt64, payload: Data) -> Data {
    var data = Data("CFA6LPAA".utf8)
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(packetNumber)
    data.appendLittleEndian(operation)
    data.append(payload)
    return data
}
