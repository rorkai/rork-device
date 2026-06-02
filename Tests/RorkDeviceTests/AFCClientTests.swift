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

    func testRemovePathDoesNotIgnoreOtherFailures() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 7))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.removePath("/busy", ignoreMissing: true) }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .afcStatus(7))
        }
    }

    func testMakeDirectoryThrowsNonZeroStatus() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 7))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.makeDirectory("/PublicStaging") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .afcStatus(7))
        }
    }

    func testRejectsInvalidMagic() async throws {
        let connection = FakeConnection(inbound: Data(repeating: 0, count: 40))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.makeDirectory("/PublicStaging") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("Invalid AFC magic."))
        }
    }

    func testRejectsUnexpectedPacketNumber() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 99, status: 0))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.makeDirectory("/PublicStaging") }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation("Unexpected AFC packet number 99, expected 1.")
            )
        }
    }

    func testRejectsInvalidPacketLengths() async throws {
        let connection = FakeConnection(inbound: afcMalformedLengthResponse(packetNumber: 1))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.makeDirectory("/PublicStaging") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("Invalid AFC packet lengths."))
        }
    }

    func testRejectsTruncatedStatusPacket() async throws {
        let connection = FakeConnection(inbound: afcResponse(packetNumber: 1, operation: 1, payload: Data([0, 0])))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.makeDirectory("/PublicStaging") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .protocolViolation("AFC status packet was truncated."))
        }
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

        try await client.uploadFile(at: fileURL, to: "/PublicStaging/App.ipa")

        XCTAssertEqual(connection.sent.count, 4)
        XCTAssertEqual(try afcPackets(connection.sent).map(afcOperation), [13, 16, 20])
        XCTAssertFalse(connection.sent[1].contains(Data("hello".utf8)))
        XCTAssertEqual(connection.sent[2], Data("hello".utf8))
    }

    func testUploadFileCanUseInMemoryData() async throws {
        var inbound = Data()
        inbound.append(afcFileOpenResponse(packetNumber: 1, handle: 99))
        inbound.append(afcStatusResponse(packetNumber: 2, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 3, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        try await client.uploadFile(Data("hello".utf8), to: "/PublicStaging/App.ipa")

        XCTAssertEqual(connection.sent.count, 4)
        XCTAssertEqual(try afcPackets(connection.sent).map(afcOperation), [13, 16, 20])
        XCTAssertFalse(connection.sent[1].contains(Data("hello".utf8)))
        XCTAssertEqual(connection.sent[2], Data("hello".utf8))
    }

    func testUploadIPAStagesInMemoryDataAtBundlePath() async throws {
        var inbound = Data()
        inbound.append(afcStatusResponse(packetNumber: 1, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 2, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 3, status: 0))
        inbound.append(afcFileOpenResponse(packetNumber: 4, handle: 99))
        inbound.append(afcStatusResponse(packetNumber: 5, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 6, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        let path = try await client.uploadIPA(Data("ipa".utf8), bundleIdentifier: "com.example.app")

        XCTAssertEqual(path, "./PublicStaging/com.example.app/app.ipa")
        XCTAssertEqual(try afcPackets(connection.sent).map(afcOperation), [9, 8, 9, 13, 16, 20])
        XCTAssertFalse(connection.sent[4].contains(Data("ipa".utf8)))
        XCTAssertEqual(connection.sent[5], Data("ipa".utf8))
    }

    func testUploadIPAIgnoresExistingStagingDirectories() async throws {
        var inbound = Data()
        inbound.append(afcStatusResponse(packetNumber: 1, status: 16))
        inbound.append(afcStatusResponse(packetNumber: 2, status: 8))
        inbound.append(afcStatusResponse(packetNumber: 3, status: 16))
        inbound.append(afcFileOpenResponse(packetNumber: 4, handle: 99))
        inbound.append(afcStatusResponse(packetNumber: 5, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 6, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        let path = try await client.uploadIPA(Data("ipa".utf8), bundleIdentifier: "com.example.app")

        XCTAssertEqual(path, "./PublicStaging/com.example.app/app.ipa")
        XCTAssertEqual(try afcPackets(connection.sent).map(afcOperation), [9, 8, 9, 13, 16, 20])
    }

    func testUploadIPARejectsUnsafeBundleIdentifier() async throws {
        let connection = FakeConnection()
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.uploadIPA(Data(), bundleIdentifier: "../App") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .invalidInput("Bundle identifier is not safe for AFC staging."))
        }
        XCTAssertTrue(connection.sent.isEmpty)
    }

    func testUploadFileThrowsWhenOpenReturnsStatusFailure() async throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 5))
        let client = AFCClient(connection: connection)

        await XCTAssertThrowsErrorAsync({ try await client.uploadFile(at: fileURL, to: "/PublicStaging/App.ipa") }) { error in
            XCTAssertEqual(error as? RorkDeviceError, .afcStatus(5))
        }
    }
}

private func afcOperation(_ packet: Data) throws -> UInt64 {
    try packet.littleEndianInteger(at: 32, as: UInt64.self)
}

private func afcPackets(_ sent: [Data]) -> [Data] {
    let magic = Data("CFA6LPAA".utf8)
    return sent.filter { $0.prefix(magic.count) == magic }
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

private func afcMalformedLengthResponse(packetNumber: UInt64) -> Data {
    var data = Data("CFA6LPAA".utf8)
    data.appendLittleEndian(UInt64(39))
    data.appendLittleEndian(UInt64(40))
    data.appendLittleEndian(packetNumber)
    data.appendLittleEndian(UInt64(1))
    return data
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
