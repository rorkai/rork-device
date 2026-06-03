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

    func testDirectoryContentsReadsNullTerminatedNames() async throws {
        let connection = FakeConnection(inbound: afcDataResponse(
            packetNumber: 1,
            payload: nullTerminated([".", "..", "Documents", "Library"])
        ))
        let client = AFCClient(connection: connection)

        let names = try await client.directoryContents(at: "/")

        XCTAssertEqual(names, [".", "..", "Documents", "Library"])
        XCTAssertEqual(try afcOperation(connection.sent[0]), 3)
        XCTAssertTrue(connection.sent[0].contains(Data("/".utf8)))
    }

    func testFileInfoParsesCommonMetadataFields() async throws {
        let connection = FakeConnection(inbound: afcDataResponse(
            packetNumber: 1,
            payload: nullTerminated([
                "st_ifmt", "S_IFREG",
                "st_size", "42",
                "LinkTarget", "/target",
            ])
        ))
        let client = AFCClient(connection: connection)

        let info = try await client.fileInfo(at: "/file.txt")

        XCTAssertEqual(info.type, .regularFile)
        XCTAssertEqual(info.size, 42)
        XCTAssertEqual(info.linkTarget, "/target")
        XCTAssertEqual(info.values["st_ifmt"], "S_IFREG")
        XCTAssertEqual(try afcOperation(connection.sent[0]), 10)
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

    func testMovePathSendsSourceAndDestination() async throws {
        let connection = FakeConnection(inbound: afcStatusResponse(packetNumber: 1, status: 0))
        let client = AFCClient(connection: connection)

        try await client.movePath(from: "/old.txt", to: "/new.txt")

        XCTAssertEqual(try afcOperation(connection.sent[0]), 24)
        XCTAssertTrue(connection.sent[0].contains(nullTerminated(["/old.txt", "/new.txt"])))
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

        XCTAssertEqual(connection.sent.count, 3)
        XCTAssertEqual(try connection.sent.map(afcOperation), [13, 16, 20])
        XCTAssertTrue(connection.sent[1].contains(Data("hello".utf8)))
    }

    func testUploadFileCanUseInMemoryData() async throws {
        var inbound = Data()
        inbound.append(afcFileOpenResponse(packetNumber: 1, handle: 99))
        inbound.append(afcStatusResponse(packetNumber: 2, status: 0))
        inbound.append(afcStatusResponse(packetNumber: 3, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        try await client.uploadFile(Data("hello".utf8), to: "/PublicStaging/App.ipa")

        XCTAssertEqual(connection.sent.count, 3)
        XCTAssertEqual(try connection.sent.map(afcOperation), [13, 16, 20])
        XCTAssertTrue(connection.sent[1].contains(Data("hello".utf8)))
    }

    func testContentsOfFileReadsUntilEmptyChunkAndClosesFile() async throws {
        var inbound = Data()
        inbound.append(afcFileOpenResponse(packetNumber: 1, handle: 99))
        inbound.append(afcDataResponse(packetNumber: 2, payload: Data("hello ".utf8)))
        inbound.append(afcDataResponse(packetNumber: 3, payload: Data("world".utf8)))
        inbound.append(afcDataResponse(packetNumber: 4, payload: Data()))
        inbound.append(afcStatusResponse(packetNumber: 5, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        let data = try await client.contentsOfFile(at: "/Documents/file.txt")

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello world")
        XCTAssertEqual(try connection.sent.map(afcOperation), [13, 15, 15, 15, 20])
    }

    func testDownloadFileWritesRemoteContentsToLocalURL() async throws {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        var inbound = Data()
        inbound.append(afcFileOpenResponse(packetNumber: 1, handle: 99))
        inbound.append(afcDataResponse(packetNumber: 2, payload: Data("file".utf8)))
        inbound.append(afcDataResponse(packetNumber: 3, payload: Data()))
        inbound.append(afcStatusResponse(packetNumber: 4, status: 0))
        let connection = FakeConnection(inbound: inbound)
        let client = AFCClient(connection: connection)

        try await client.downloadFile(from: "/Documents/file.txt", to: outputURL)

        XCTAssertEqual(try Data(contentsOf: outputURL), Data("file".utf8))
        XCTAssertEqual(try connection.sent.map(afcOperation), [13, 15, 15, 20])
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
        XCTAssertEqual(try connection.sent.map(afcOperation), [9, 8, 9, 13, 16, 20])
        XCTAssertTrue(connection.sent[4].contains(Data("ipa".utf8)))
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
        XCTAssertEqual(try connection.sent.map(afcOperation), [9, 8, 9, 13, 16, 20])
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

private func afcStatusResponse(packetNumber: UInt64, status: UInt64) -> Data {
    var payload = Data()
    payload.appendLittleEndian(status)
    return afcResponse(packetNumber: packetNumber, operation: 1, payload: payload)
}

private func afcDataResponse(packetNumber: UInt64, payload: Data) -> Data {
    afcResponse(packetNumber: packetNumber, operation: 2, payload: payload)
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

private func nullTerminated(_ strings: [String]) -> Data {
    var data = Data()
    for string in strings {
        data.append(contentsOf: string.utf8)
        data.append(0)
    }
    return data
}
