import Foundation
import XCTest
@testable import RorkDevice

final class RemoteXPCConnectionTests: XCTestCase {
    func testOpensTheHTTP2SessionAndExchangesMessagesOnTheControlStream() async throws {
        let response = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "result": .data(Data([0x01, 0x02, 0x03])),
            ]),
            flags: 0x00000101,
            messageIdentifier: 7
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: response
            )
        )
        let connection = FakeConnection(inbound: inbound)

        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        try await remoteXPC.send(
            .dictionary([
                "request": .string("pair"),
            ])
        )
        let message = try await remoteXPC.receive()

        XCTAssertEqual(
            message.value,
            .dictionary([
                "result": .data(Data([0x01, 0x02, 0x03])),
            ])
        )
        XCTAssertEqual(
            connection.sent.first,
            Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        )

        let requestFrame = try XCTUnwrap(
            connection.sent.reversed().first { frame in
                guard frame.count >= 9, frame[3] == 0x00 else {
                    return false
                }
                let streamIdentifier =
                    (UInt32(frame[5]) << 24)
                    | (UInt32(frame[6]) << 16)
                    | (UInt32(frame[7]) << 8)
                    | UInt32(frame[8])
                return streamIdentifier == 1
            }
        )
        let request = try XCTUnwrap(
            RemoteXPCMessageCodec.decodeFirstMessage(
                from: Data(requestFrame.dropFirst(9))
            )
        ).message
        XCTAssertEqual(request.flags, 0x00000101)
        XCTAssertEqual(request.messageIdentifier, 1)
        XCTAssertEqual(
            request.value,
            .dictionary([
                "request": .string("pair"),
            ])
        )
    }

    func testBuffersMessagesFromTheOtherRemoteXPCStream() async throws {
        let replyStreamMessage = try RemoteXPCMessageCodec.encode(
            value: .string("reply"),
            flags: 0x00000101,
            messageIdentifier: 2
        )
        let controlStreamMessage = try RemoteXPCMessageCodec.encode(
            value: .string("control"),
            flags: 0x00000101,
            messageIdentifier: 3
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: replyStreamMessage
            )
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: controlStreamMessage
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        let control = try await remoteXPC.receive()
        let reply = try await remoteXPC.receive(on: .reply)

        XCTAssertEqual(control.value, .string("control"))
        XCTAssertEqual(reply.value, .string("reply"))
    }

    func testConsumesChannelHandshakeRepliesBeforeExposingServiceMessages() async throws {
        let serviceReply = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": .dictionary([:]),
            ]),
            flags: 0x00020101,
            messageIdentifier: 1
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: serviceReply
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        let message = try await remoteXPC.receive(on: .reply)

        XCTAssertEqual(
            message.value,
            .dictionary([
                "CoreDevice.output": .dictionary([:]),
            ])
        )
    }

    func testRejectsDataOnAnUnexpectedHTTP2Stream() async throws {
        let unexpectedMessage = try RemoteXPCMessageCodec.encode(
            value: .string("unexpected"),
            flags: 0x00000101,
            messageIdentifier: 1
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 5,
                payload: unexpectedMessage
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await remoteXPC.receive()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "RemoteXPC received DATA on unexpected HTTP/2 stream 5."
                )
            )
        }
    }

    func testPreservesTheHTTP2ErrorCodeWhenThePeerResetsAStream() async throws {
        var resetPayload = Data()
        resetPayload.appendBigEndian(UInt32(0x08))
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x03,
                streamIdentifier: 1,
                payload: resetPayload
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await remoteXPC.receive()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remoteXPCStreamReset(
                    streamIdentifier: 1,
                    errorCode: 0x08
                )
            )
        }
    }

    func testRejectsAStreamResetWithoutACompleteHTTP2ErrorCode() async throws {
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x03,
                streamIdentifier: 1,
                payload: Data([0x08])
            )
        )
        let remoteXPC = try await RemoteXPCConnection.open(
            over: FakeConnection(inbound: inbound)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await remoteXPC.receive()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "RemoteXPC HTTP/2 RST_STREAM payload must contain a 32-bit error code."
                )
            )
        }
    }

    func testConcurrentSendsReserveDistinctMessageIdentifiers() async throws {
        let sendBlocked = expectation(
            description: "The first application send is suspended."
        )
        let connection = BlockingRemoteXPCConnection(
            inbound: try remoteXPCSessionHandshakeInbound(),
            blocking: .send(10),
            blockedExpectation: sendBlocked
        )
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        let first = Task {
            try await remoteXPC.send(.string("first"))
        }
        await fulfillment(of: [sendBlocked], timeout: 1)
        let second = Task {
            try await remoteXPC.send(.string("second"))
        }

        await Task.yield()
        connection.release()
        try await first.value
        try await second.value

        let identifiers = try connection.sentData.compactMap {
            frame -> UInt64? in
            guard frame.count >= 9,
                  frame[3] == 0x00,
                  Data(frame[5...8]) == Data([0, 0, 0, 1]),
                  let decoded = try RemoteXPCMessageCodec.decodeFirstMessage(
                      from: Data(frame.dropFirst(9))
                  ),
                  decoded.message.messageIdentifier > 0 else {
                return nil
            }
            return decoded.message.messageIdentifier
        }
        XCTAssertEqual(identifiers, [1, 2])
    }

    func testConcurrentSendsDoNotOverlapTransportWrites() async throws {
        let connection = OverlapRejectingRemoteXPCConnection(
            inbound: try remoteXPCSessionHandshakeInbound()
        )
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<20 {
                group.addTask {
                    try await remoteXPC.send(.uint64(UInt64(value)))
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(connection.maximumConcurrentSendCount, 1)
    }

    func testRejectsConcurrentReceivesOnOneConnection() async throws {
        let receiveBlocked = expectation(
            description: "The first application receive is suspended."
        )
        let connection = BlockingRemoteXPCConnection(
            inbound: try remoteXPCSessionHandshakeInbound(),
            blocking: .receive(9),
            blockedExpectation: receiveBlocked
        )
        let remoteXPC = try await RemoteXPCConnection.open(over: connection)
        let first = Task {
            try await remoteXPC.receive()
        }
        await fulfillment(of: [receiveBlocked], timeout: 1)

        await XCTAssertThrowsErrorAsync({
            _ = try await remoteXPC.receive()
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Concurrent RemoteXPC receive operations are not supported."
                )
            )
        }

        connection.release()
        _ = try? await first.value
    }
}

/// Test transport that rejects overlapping writes.
///
/// RemoteXPC permits concurrent callers but must deliver each encoded HTTP/2
/// frame through the underlying byte stream only after the previous write has
/// completed. A short suspension makes actor reentrancy deterministic without
/// depending on frame contents or task scheduling order.
private final class OverlapRejectingRemoteXPCConnection:
    DeviceConnection,
    @unchecked Sendable
{
    /// Protects stream bytes and concurrent-write accounting.
    private let lock = NSLock()

    /// Inbound bytes consumed by exact reads.
    private var inbound: Data

    /// Number of transport writes that have not completed.
    private var activeSendCount = 0

    /// Highest number of writes observed at the same time.
    private var recordedMaximumConcurrentSendCount = 0

    /// Whether local closure has made future operations invalid.
    private var isClosed = false

    /// Thread-safe snapshot of the highest concurrent-write count.
    var maximumConcurrentSendCount: Int {
        lock.withLock { recordedMaximumConcurrentSendCount }
    }

    /// Creates a stream with the supplied RemoteXPC handshake replies.
    init(inbound: Data) {
        self.inbound = inbound
    }

    /// Rejects a write when another write is still suspended.
    func send(_: Data) async throws {
        let overlapsExistingSend = try lock.withLock {
            try ensureOpen()
            activeSendCount += 1
            recordedMaximumConcurrentSendCount = max(
                recordedMaximumConcurrentSendCount,
                activeSendCount
            )
            return activeSendCount > 1
        }
        guard !overlapsExistingSend else {
            lock.withLock {
                activeSendCount -= 1
            }
            throw RorkDeviceError.protocolViolation(
                "RemoteXPC transport writes overlapped."
            )
        }

        defer {
            lock.withLock {
                activeSendCount -= 1
            }
        }
        try await Task.sleep(for: .milliseconds(5))
    }

    /// Reads exactly the requested bytes from the prepared handshake stream.
    func receive(exactly count: Int) async throws -> Data {
        try lock.withLock {
            try ensureOpen()
            guard inbound.count >= count else {
                throw RorkDeviceError.transport(
                    "Overlap-rejecting RemoteXPC connection underflow."
                )
            }
            let data = Data(inbound.prefix(count))
            inbound.removeFirst(count)
            return data
        }
    }

    /// Closes the test stream.
    func close() {
        lock.withLock {
            isClosed = true
        }
    }

    /// Rejects operations after local closure.
    private func ensureOpen() throws {
        guard !isClosed else {
            throw RorkDeviceError.transport(
                "Overlap-rejecting RemoteXPC connection is closed."
            )
        }
    }
}

/// Deterministic byte stream that suspends one selected protocol operation.
///
/// RemoteXPC startup performs a fixed series of reads and writes. Selecting an
/// operation by ordinal lets concurrency tests pause the first application
/// operation after startup without adding hooks to production code.
private final class BlockingRemoteXPCConnection:
    DeviceConnection,
    @unchecked Sendable
{
    /// Operation and one-based invocation number to suspend.
    enum Operation: Equatable {
        case send(Int)
        case receive(Int)
    }

    /// Protects stream bytes, counters, and suspension state.
    private let lock = NSLock()

    /// Operation selected by the test.
    private let blockedOperation: Operation

    /// Expectation fulfilled after the suspension continuation is installed.
    private let blockedExpectation: XCTestExpectation

    /// Inbound bytes consumed by exact reads.
    private var inbound: Data

    /// Complete outbound buffers in invocation order.
    private var sent: [Data] = []

    /// Number of send and receive calls observed since construction.
    private var sendCount = 0
    private var receiveCount = 0

    /// Continuation for the selected operation while it is suspended.
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    /// Whether local closure has made future operations invalid.
    private var isClosed = false

    /// Thread-safe snapshot of complete outbound buffers.
    var sentData: [Data] {
        lock.withLock { sent }
    }

    /// Creates a stream with one operation-level suspension point.
    init(
        inbound: Data,
        blocking operation: Operation,
        blockedExpectation: XCTestExpectation
    ) {
        self.inbound = inbound
        blockedOperation = operation
        self.blockedExpectation = blockedExpectation
    }

    /// Records one complete write and suspends the selected invocation.
    func send(_ data: Data) async throws {
        let shouldBlock = try lock.withLock {
            try ensureOpen()
            sendCount += 1
            sent.append(data)
            return blockedOperation == .send(sendCount)
        }
        if shouldBlock {
            await suspendSelectedOperation()
        }
    }

    /// Reads exactly the requested bytes after any selected suspension.
    func receive(exactly count: Int) async throws -> Data {
        let shouldBlock = try lock.withLock {
            try ensureOpen()
            receiveCount += 1
            return blockedOperation == .receive(receiveCount)
        }
        if shouldBlock {
            await suspendSelectedOperation()
        }

        return try lock.withLock {
            try ensureOpen()
            guard inbound.count >= count else {
                throw RorkDeviceError.transport(
                    "Blocking RemoteXPC connection underflow."
                )
            }
            let data = Data(inbound.prefix(count))
            inbound.removeFirst(count)
            return data
        }
    }

    /// Closes the stream and releases a suspended operation.
    func close() {
        let continuation = lock.withLock {
            isClosed = true
            let continuation = blockedContinuation
            blockedContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    /// Releases the operation selected by the test.
    func release() {
        let continuation = lock.withLock {
            let continuation = blockedContinuation
            blockedContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    /// Suspends after installing the continuation observed by the test.
    private func suspendSelectedOperation() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                blockedContinuation = continuation
            }
            blockedExpectation.fulfill()
        }
    }

    /// Rejects operations after local closure.
    private func ensureOpen() throws {
        guard !isClosed else {
            throw RorkDeviceError.transport(
                "Blocking RemoteXPC connection is closed."
            )
        }
    }
}
