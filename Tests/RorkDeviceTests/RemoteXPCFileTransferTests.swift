import Foundation
import XCTest

@testable import RorkDevice

final class RemoteXPCFileTransferTests: XCTestCase {
    func testFileTransferValueRoundTripsWithItsIdentifierAndSize() throws {
        let value = RemoteXPCValue.dictionary([
            "image": .fileTransfer(identifier: 2, size: 70_000),
        ])

        let encoded = try RemoteXPCMessageCodec.encode(
            value: value,
            flags: 0x00000101,
            messageIdentifier: 1
        )
        let decoded = try XCTUnwrap(
            RemoteXPCMessageCodec.decodeFirstMessage(from: encoded)
        ).message

        XCTAssertEqual(decoded.value, value)
        var tagAndIdentifier = Data()
        tagAndIdentifier.appendLittleEndian(UInt32(0x0001_a000))
        tagAndIdentifier.appendLittleEndian(UInt64(2))
        XCTAssertNotNil(encoded.range(of: tagAndIdentifier))
    }

    func testUploadAnnouncesStreamsAndWaitsForWindowUpdates() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(initialWindowSettings(4))
        inbound.append(try fileOpenReply(identifier: 2, on: 5))
        // Each 24-byte file-open message already spent that much of its
        // stream's window, so the first grant only brings it back to four.
        inbound.append(windowUpdate(24, on: 5))
        inbound.append(windowUpdate(4, on: 5))
        inbound.append(windowUpdate(4, on: 5))
        inbound.append(try fileOpenReply(identifier: 3, on: 7))
        inbound.append(windowUpdate(24, on: 7))
        inbound.append(
            remoteXPCTestFrame(
                type: 0x03,
                streamIdentifier: 5,
                payload: Data([0, 0, 0, 0])
            )
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: try RemoteXPCMessageCodec.encode(
                    value: .dictionary(["argv": .dictionary([:])]),
                    flags: 0x00020101,
                    messageIdentifier: 1
                )
            )
        )
        let connection = FakeConnection(inbound: inbound)
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        let handshakeFrameCount = connection.sent.count
        var transfers: [RemoteXPCValue] = []

        let outcome = try await remoteXPC.send(
            uploading: [
                .data(Data("0123456789".utf8)),
                .data(Data("abc".utf8)),
            ],
            additionalFlags: 0x00010000
        ) { values in
            transfers = values
            return .dictionary(["files": .array(values)])
        }
        let reply = try await remoteXPC.receive(on: .reply)

        XCTAssertEqual(outcome, .uploaded)
        XCTAssertEqual(reply.value, .dictionary(["argv": .dictionary([:])]))
        XCTAssertEqual(
            transfers,
            [
                .fileTransfer(identifier: 2, size: 10),
                .fileTransfer(identifier: 3, size: 3),
            ]
        )
        let frames = try sentFrames(
            Array(connection.sent.dropFirst(handshakeFrameCount))
        )
        XCTAssertEqual(
            frames.map { "\($0.type)/\($0.streamIdentifier)" },
            [
                "1/5", "0/5", "1/7", "0/7", "0/1", "4/0",
                "0/5", "0/5", "0/5", "0/5", "0/7", "0/7",
            ]
        )
        let fileOpen = try XCTUnwrap(
            RemoteXPCMessageCodec.decodeFirstMessage(from: frames[1].payload)
        ).message
        XCTAssertEqual(fileOpen.flags, 0x00100001)
        XCTAssertEqual(fileOpen.messageIdentifier, 2)
        let request = try XCTUnwrap(
            RemoteXPCMessageCodec.decodeFirstMessage(from: frames[4].payload)
        ).message
        XCTAssertEqual(request.messageIdentifier, 1)
        XCTAssertEqual(request.flags, 0x00010101)
        XCTAssertEqual(
            frames[6...8].map { String(decoding: $0.payload, as: UTF8.self) },
            ["0123", "4567", "89"]
        )
        XCTAssertEqual(frames[9].flags, 0x01)
        XCTAssertTrue(frames[9].payload.isEmpty)
        XCTAssertEqual(String(decoding: frames[10].payload, as: UTF8.self), "abc")
        XCTAssertEqual(frames[11].flags, 0x01)
    }

    func testUploadFailsWhenThePeerResetsItsStream() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(initialWindowSettings(4))
        inbound.append(try fileOpenReply(identifier: 2, on: 5))
        inbound.append(
            remoteXPCTestFrame(
                type: 0x03,
                streamIdentifier: 5,
                payload: Data([0, 0, 0, 8])
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [.data(Data("0123456789".utf8))]
            ) { values in
                .array(values)
            }
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remoteXPCStreamReset(streamIdentifier: 5, errorCode: 8)
            )
        }
    }

    func testUploadFailsWhenThePeerResetsAPendingStream() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(initialWindowSettings(4))
        inbound.append(try fileOpenReply(identifier: 2, on: 5))
        inbound.append(
            remoteXPCTestFrame(
                type: 0x03,
                streamIdentifier: 7,
                payload: Data([0, 0, 0, 3])
            )
        )
        let connection = FakeConnection(inbound: inbound)
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        let handshakeFrameCount = connection.sent.count

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [
                    .data(Data("0123456789".utf8)),
                    .data(Data("abc".utf8)),
                ]
            ) { values in
                .array(values)
            }
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remoteXPCStreamReset(streamIdentifier: 7, errorCode: 3)
            )
        }
        let uploadedData = try sentFrames(
            Array(connection.sent.dropFirst(handshakeFrameCount))
        ).filter { $0.type == 0x00 && $0.streamIdentifier == 5 }.dropFirst()
        XCTAssertTrue(uploadedData.isEmpty)
    }

    func testUploadFailsWhenThePeerEndsAStreamWithoutAcceptingIt() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                flags: 0x01,
                streamIdentifier: 5,
                payload: Data()
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [.data(Data("0".utf8))]
            ) { values in
                .array(values)
            }
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "RemoteXPC file transfer 2 ended on stream 5 before the peer accepted it."
                )
            )
        }
    }

    func testUploadStopsWhenThePeerRepliesBeforeAcceptingAStream() async throws {
        let refusal = RemoteXPCValue.dictionary(["error": .uint64(22)])
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: try RemoteXPCMessageCodec.encode(
                    value: refusal,
                    flags: 0x00020101,
                    messageIdentifier: 1
                )
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        let outcome = try await remoteXPC.send(
            uploading: [.data(Data("0".utf8))]
        ) { values in
            .array(values)
        }
        let reply = try await remoteXPC.receive(on: .reply)

        XCTAssertEqual(outcome, .answeredBeforeUploadFinished)
        XCTAssertEqual(reply.value, refusal)
    }

    func testUploadStopsWhenThePeerRepliesWhileItWaitsForCredit() async throws {
        let refusal = RemoteXPCValue.dictionary(["error": .uint64(22)])
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(initialWindowSettings(24))
        inbound.append(try fileOpenReply(identifier: 2, on: 5))
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: try RemoteXPCMessageCodec.encode(
                    value: refusal,
                    flags: 0x00020101,
                    messageIdentifier: 1
                )
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        let outcome = try await remoteXPC.send(
            uploading: [.data(Data("0".utf8))]
        ) { values in
            .array(values)
        }

        XCTAssertEqual(outcome, .answeredBeforeUploadFinished)
    }

    func testUploadRejectsMoreTransfersThanThePeerAllowsConcurrently() async throws {
        var settings = Data()
        settings.appendBigEndian(UInt16(0x3))
        settings.appendBigEndian(UInt32(4))
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(type: 0x04, streamIdentifier: 0, payload: settings)
        )
        let connection = FakeConnection(inbound: inbound)
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        // The SETTINGS frame is read while the first receive waits.
        _ = try? await remoteXPC.receive(on: .reply)
        let sentBeforeUpload = connection.sent.count

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [
                    .data(Data("a".utf8)),
                    .data(Data("b".utf8)),
                    .data(Data("c".utf8)),
                ]
            ) { values in
                .array(values)
            }
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "RemoteXPC peer allows 4 concurrent streams, too few for 3 file transfers beside 2 open streams."
                )
            )
        }
        XCTAssertEqual(connection.sent.count, sentBeforeUpload)
    }

    func testUploadReleasesStreamsBothEndsHaveClosed() async throws {
        var settings = Data()
        settings.appendBigEndian(UInt16(0x3))
        settings.appendBigEndian(UInt32(3))
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(type: 0x04, streamIdentifier: 0, payload: settings)
        )
        inbound.append(try fileOpenReply(identifier: 2, on: 5))
        inbound.append(
            remoteXPCTestFrame(type: 0x00, flags: 0x01, streamIdentifier: 5)
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: try RemoteXPCMessageCodec.encode(
                    value: .dictionary([:]),
                    flags: 0x00020101,
                    messageIdentifier: 1
                )
            )
        )
        inbound.append(try fileOpenReply(identifier: 4, on: 7))
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        let first = try await remoteXPC.send(
            uploading: [.data(Data("a".utf8))]
        ) { values in
            .array(values)
        }
        _ = try await remoteXPC.receive(on: .reply)
        let second = try await remoteXPC.send(
            uploading: [.data(Data("b".utf8))]
        ) { values in
            .array(values)
        }

        XCTAssertEqual(first, .uploaded)
        XCTAssertEqual(second, .uploaded)
    }

    func testFileOpenMessageWaitsForStreamWindowCredit() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(initialWindowSettings(10))
        let connection = FakeConnection(inbound: inbound)
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        // The SETTINGS frame is read while the first receive waits.
        _ = try? await remoteXPC.receive(on: .reply)
        let sentBeforeUpload = connection.sent.count

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [.data(Data("0".utf8))]
            ) { values in
                .array(values)
            }
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport("Fake connection underflow.")
            )
        }
        let frames = try sentFrames(
            Array(connection.sent.dropFirst(sentBeforeUpload))
        )
        XCTAssertEqual(frames.map { "\($0.type)/\($0.streamIdentifier)" }, ["1/5"])
    }

    func testFileOpenMessageCountsAgainstItsStreamWindow() throws {
        var flowControl = RemoteXPCSendFlowControl(
            initialWindowSize: 100,
            maximumFrameSize: 16_384
        )
        let stream = flowControl.openStream()
        flowControl.grant(1_000, on: 0)

        flowControl.charge(24, on: stream)

        XCTAssertEqual(try flowControl.reserve(upTo: 1_000, on: stream), 76)
    }

    func testSettingsRejectSizesOutsideTheirRanges() throws {
        func settings(_ identifier: UInt16, _ value: UInt32) -> Data {
            var payload = Data()
            payload.appendBigEndian(identifier)
            payload.appendBigEndian(value)
            return payload
        }
        var flowControl = RemoteXPCSendFlowControl(
            initialWindowSize: 65_535,
            maximumFrameSize: 16_384
        )

        XCTAssertThrowsError(try flowControl.apply(settings: settings(0x5, 0)))
        XCTAssertThrowsError(
            try flowControl.apply(settings: settings(0x5, 16_777_216))
        )
        XCTAssertThrowsError(
            try flowControl.apply(settings: settings(0x4, 0x8000_0000))
        )
        try flowControl.apply(settings: settings(0x5, 20_000))
        let stream = flowControl.openStream()
        flowControl.grant(100_000, on: 0)
        flowControl.grant(100_000, on: stream)
        XCTAssertEqual(try flowControl.reserve(upTo: 50_000, on: stream), 20_000)
    }

    func testUploadRejectsAStreamAcceptedForAnotherTransfer() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(try fileOpenReply(identifier: 9, on: 5))
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            try await remoteXPC.send(
                uploading: [.data(Data("0".utf8))]
            ) { values in
                .array(values)
            }
        }) { error in
            guard case .protocolViolation? = error as? RorkDeviceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

/// One HTTP/2 frame the host wrote.
struct SentHTTP2Frame {
    let type: UInt8
    let flags: UInt8
    let streamIdentifier: UInt32
    let payload: Data
}

/// Decodes the frames a RemoteXPC connection wrote, one per send call.
func sentFrames(_ writes: [Data]) throws -> [SentHTTP2Frame] {
    try writes.map { write in
        guard write.count >= 9 else {
            throw RorkDeviceError.protocolViolation(
                "Captured write is not an HTTP/2 frame."
            )
        }
        let stream: UInt32 = try write.bigEndianInteger(at: 5)
        return SentHTTP2Frame(
            type: write[write.startIndex + 3],
            flags: write[write.startIndex + 4],
            streamIdentifier: stream & 0x7fff_ffff,
            payload: Data(write.dropFirst(9))
        )
    }
}

/// Builds the peer's acceptance of the file transfer on a stream.
func fileOpenReply(identifier: UInt64, on stream: UInt32) throws -> Data {
    remoteXPCTestFrame(
        type: 0x00,
        streamIdentifier: stream,
        payload: try RemoteXPCMessageCodec.encode(
            value: nil,
            flags: 0x00200001,
            messageIdentifier: identifier
        )
    )
}

/// Builds a SETTINGS frame announcing an initial stream window.
private func initialWindowSettings(_ size: UInt32) -> Data {
    var payload = Data()
    payload.appendBigEndian(UInt16(0x4))
    payload.appendBigEndian(size)
    return remoteXPCTestFrame(type: 0x04, streamIdentifier: 0, payload: payload)
}

/// Builds a WINDOW_UPDATE frame for a stream.
private func windowUpdate(_ increment: UInt32, on stream: UInt32) -> Data {
    var payload = Data()
    payload.appendBigEndian(increment)
    return remoteXPCTestFrame(
        type: 0x08,
        streamIdentifier: stream,
        payload: payload
    )
}
