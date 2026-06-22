import Foundation
import RorkDevice
import XCTest

@testable import RorkDeviceWeb

final class DirectUSBMuxSessionTests: XCTestCase {
    func testNegotiatesVersionTwoBeforeOpeningServiceConnection() async throws {
        let pipe = DirectUSBMuxTestPipe()

        let session = try await openSession(over: pipe)

        let connectTask = Task {
            try await session.connect(to: 62_078)
        }
        let synPacket = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(synPacket.destinationPort, 62_078)
        XCTAssertEqual(synPacket.sequenceNumber, 0)
        XCTAssertEqual(synPacket.acknowledgmentNumber, 0)
        XCTAssertEqual(synPacket.flags, [.synchronize])

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: synPacket.destinationPort,
                    destinationPort: synPacket.sourcePort,
                    sequenceNumber: 400,
                    acknowledgmentNumber: 1,
                    flags: [.synchronize, .acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 1
            )
        )

        let acknowledgment = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(
            acknowledgment.flags,
            [.acknowledgment]
        )
        XCTAssertEqual(acknowledgment.sequenceNumber, 1)
        XCTAssertEqual(acknowledgment.acknowledgmentNumber, 401)

        let connection = try await connectTask.value
        connection.close()
        await session.close()
    }

    func testDuplicateVersionFrameDoesNotInterruptServiceConnection() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)

        let connectTask = Task {
            try await session.connect(to: 62_078)
        }
        let synPacket = try await nextTCPPacket(from: pipe)
        let codec = DirectUSBMuxPacketCodec()
        var devicePackets = try codec.encode(
            protocol: .version,
            payload: Data(),
            header: .sequenced(
                transmitSequence: 1,
                receiveSequence: 1
            )
        )
        devicePackets.append(
            try muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: synPacket.destinationPort,
                    destinationPort: synPacket.sourcePort,
                    sequenceNumber: 400,
                    acknowledgmentNumber: 1,
                    flags: [.synchronize, .acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 2
            )
        )
        try await pipe.enqueueRead(devicePackets)

        let connection = try await connectTask.value
        let acknowledgment = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(acknowledgment.flags, [.acknowledgment])

        connection.close()
        await session.close()
    }

    func testOutgoingPacketAcknowledgesLatestMuxReceiveSequence() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)

        let connectTask = Task {
            try await session.connect(to: 62_078)
        }
        let synPacket = try await nextTCPPacket(from: pipe)
        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: synPacket.destinationPort,
                    destinationPort: synPacket.sourcePort,
                    sequenceNumber: 400,
                    acknowledgmentNumber: 1,
                    flags: [.synchronize, .acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 1,
                receiveSequence: 42
            )
        )

        let connection = try await connectTask.value
        let acknowledgment = try await nextMuxPacket(from: pipe)
        XCTAssertEqual(
            acknowledgment.header,
            .sequenced(
                transmitSequence: 2,
                receiveSequence: 42
            )
        )

        connection.close()
        await session.close()
    }

    func testConnectionRoutesPayloadAndAcknowledgesDeviceData() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 100
        )

        try await connection.send(Data([1, 2, 3]))
        let outbound = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(outbound.sequenceNumber, 1)
        XCTAssertEqual(outbound.acknowledgmentNumber, 101)
        XCTAssertEqual(outbound.flags, [.acknowledgment])
        XCTAssertEqual(outbound.payload, Data([1, 2, 3]))

        let receiveTask = Task {
            try await connection.receive(exactly: 4)
        }
        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: outbound.destinationPort,
                    destinationPort: outbound.sourcePort,
                    sequenceNumber: 101,
                    acknowledgmentNumber: 4,
                    flags: [.acknowledgment],
                    windowSize: 512,
                    payload: Data([4, 5, 6, 7])
                ),
                transmitSequence: 2
            )
        )

        let received = try await receiveTask.value
        XCTAssertEqual(received, Data([4, 5, 6, 7]))
        let acknowledgment = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(acknowledgment.payload, Data())
        XCTAssertEqual(acknowledgment.acknowledgmentNumber, 105)

        connection.close()
        await session.close()
    }

    func testServicePayloadStaysWithinDeviceMuxPacketLimit() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 100
        )

        try await connection.send(
            Data(repeating: 0xaa, count: 65_500)
        )

        let packet = await pipe.nextWrite()
        XCTAssertEqual(packet.count, 65_535)

        connection.close()
        await session.close()
    }

    func testServicePayloadAvoidsUSBPacketBoundary() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 100
        )
        let payload = Data(repeating: 0xaa, count: 476)

        try await connection.send(payload)

        let writes = await pipe.takeWrites()
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(
            writes.allSatisfy {
                !$0.count.isMultiple(of: 512)
            }
        )
        let packets = try writes.map(decodeTCPPacket)
        XCTAssertEqual(
            packets.reduce(into: Data()) {
                $0.append($1.payload)
            },
            payload
        )

        connection.close()
        await session.close()
    }

    func testAcknowledgmentDuringSuspendedWriteKeepsConnectionUsable() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 100
        )

        await pipe.suspendNextWrite()
        let sendTask = Task {
            try await connection.send(Data([1, 2, 3]))
        }
        let suspendedWrite = await pipe.nextSuspendedWrite()
        let outbound = try decodeTCPPacket(suspendedWrite)
        XCTAssertEqual(outbound.sequenceNumber, 1)
        XCTAssertEqual(outbound.payload, Data([1, 2, 3]))

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: outbound.destinationPort,
                    destinationPort: outbound.sourcePort,
                    sequenceNumber: 101,
                    acknowledgmentNumber: 4,
                    flags: [.acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 2
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        await pipe.resumeSuspendedWrite()
        try await sendTask.value

        try await connection.send(Data([4]))
        let nextOutbound = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(nextOutbound.sequenceNumber, 4)
        XCTAssertEqual(nextOutbound.payload, Data([4]))

        connection.close()
        await session.close()
    }

    func testDuplicatePayloadAcrossSequenceWrapKeepsConnectionUsable() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: UInt32.max - 1
        )
        let wrappedPayload = DirectUSBMuxTCPPacket(
            sourcePort: connection.remotePort,
            destinationPort: connection.localPort,
            sequenceNumber: UInt32.max,
            acknowledgmentNumber: 1,
            flags: [.acknowledgment],
            windowSize: 512,
            payload: Data([1, 2])
        )

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: wrappedPayload,
                transmitSequence: 2
            )
        )
        let received = try await connection.receive(exactly: 2)
        XCTAssertEqual(
            received,
            Data([1, 2])
        )
        let firstAcknowledgment = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(firstAcknowledgment.acknowledgmentNumber, 1)

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: wrappedPayload,
                transmitSequence: 3
            )
        )
        let duplicateAcknowledgment = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(duplicateAcknowledgment.acknowledgmentNumber, 1)
        try await connection.send(Data([3]))
        let outbound = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(outbound.payload, Data([3]))

        connection.close()
        await session.close()
    }

    func testConcurrentReceiveReturnsAnErrorInsteadOfTrapping() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let connection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 100
        )

        try await withThrowingTaskGroup(
            of: Result<Data, any Error>.self
        ) { reads in
            for _ in 0..<2 {
                reads.addTask {
                    do {
                        return .success(
                            try await connection.receive(upTo: 1)
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            }

            let nextConcurrentResult = try await reads.next()
            let concurrentResult = try XCTUnwrap(nextConcurrentResult)
            guard case .failure(let error) = concurrentResult else {
                return XCTFail(
                    "Expected one concurrent read to fail before data arrived."
                )
            }
            XCTAssertEqual(
                error as? DirectUSBMuxError,
                .concurrentReadNotSupported(
                    localPort: connection.localPort
                )
            )

            try await pipe.enqueueRead(
                muxPacket(
                    tcpPacket: DirectUSBMuxTCPPacket(
                        sourcePort: connection.remotePort,
                        destinationPort: connection.localPort,
                        sequenceNumber: 101,
                        acknowledgmentNumber: 1,
                        flags: [.acknowledgment],
                        windowSize: 512,
                        payload: Data([0xaa])
                    ),
                    transmitSequence: 2
                )
            )
            let nextSuccessfulResult = try await reads.next()
            let successfulResult = try XCTUnwrap(nextSuccessfulResult)
            guard case .success(let data) = successfulResult else {
                return XCTFail(
                    "Expected the remaining read to receive device data."
                )
            }
            XCTAssertEqual(data, Data([0xaa]))
            _ = try await nextTCPPacket(from: pipe)
        }

        connection.close()
        await session.close()
    }

    func testIndependentConnectionsReceiveOnlyTheirOwnPayload() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let first = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 10
        )
        let second = try await openConnection(
            to: 12_345,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 20
        )

        let firstRead = Task {
            try await first.receive(upTo: 32)
        }
        let secondRead = Task {
            try await second.receive(upTo: 32)
        }

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: second.remotePort,
                    destinationPort: second.localPort,
                    sequenceNumber: 21,
                    acknowledgmentNumber: 1,
                    flags: [.acknowledgment],
                    windowSize: 512,
                    payload: Data("second".utf8)
                ),
                transmitSequence: 3
            )
        )
        _ = try await nextTCPPacket(from: pipe)

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: first.remotePort,
                    destinationPort: first.localPort,
                    sequenceNumber: 11,
                    acknowledgmentNumber: 1,
                    flags: [.acknowledgment],
                    windowSize: 512,
                    payload: Data("first".utf8)
                ),
                transmitSequence: 4
            )
        )
        _ = try await nextTCPPacket(from: pipe)

        let firstData = try await firstRead.value
        let secondData = try await secondRead.value
        XCTAssertEqual(firstData, Data("first".utf8))
        XCTAssertEqual(secondData, Data("second".utf8))

        first.close()
        second.close()
        await session.close()
    }

    func testResetFailsPendingReadWithoutClosingOtherConnections() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let resetConnection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 50
        )
        let healthyConnection = try await openConnection(
            to: 12_345,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 70
        )

        let readTask = Task {
            try await resetConnection.receive(upTo: 32)
        }
        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: resetConnection.remotePort,
                    destinationPort: resetConnection.localPort,
                    sequenceNumber: 51,
                    acknowledgmentNumber: 1,
                    flags: [.reset],
                    windowSize: 0,
                    payload: Data("refused".utf8)
                ),
                transmitSequence: 5
            )
        )

        do {
            _ = try await readTask.value
            XCTFail("Expected the reset connection to fail.")
        } catch let error as DirectUSBMuxError {
            XCTAssertEqual(
                error,
                .connectionReset(
                    localPort: resetConnection.localPort,
                    remotePort: resetConnection.remotePort,
                    reason: "refused"
                )
            )
        }

        try await healthyConnection.send(Data([0xaa]))
        let healthyPacket = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(
            healthyPacket.payload,
            Data([0xaa])
        )

        healthyConnection.close()
        await session.close()
    }

    func testAcknowledgmentBeyondSentDataFailsOnlyThatConnection() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let invalidConnection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 50
        )
        let healthyConnection = try await openConnection(
            to: 12_345,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 70
        )
        let invalidRead = Task {
            try await invalidConnection.receive(upTo: 1)
        }

        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: invalidConnection.remotePort,
                    destinationPort: invalidConnection.localPort,
                    sequenceNumber: 51,
                    acknowledgmentNumber: 2,
                    flags: [.acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 5
            )
        )

        do {
            _ = try await invalidRead.value
            XCTFail("Expected the invalid acknowledgment to fail the stream.")
        } catch let error as DirectUSBMuxError {
            XCTAssertEqual(
                error,
                .invalidAcknowledgment(
                    localPort: invalidConnection.localPort,
                    sentSequence: 1,
                    acknowledgedSequence: 2
                )
            )
        }

        let reset = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(reset.flags, [.reset])
        try await healthyConnection.send(Data([0xbb]))
        let healthyPacket = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(healthyPacket.payload, Data([0xbb]))

        healthyConnection.close()
        await session.close()
    }

    func testReceiveBufferOverflowFailsOnlyThatConnection() async throws {
        let pipe = DirectUSBMuxTestPipe()
        let session = try await openSession(over: pipe)
        let overflowingConnection = try await openConnection(
            to: 62_078,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 50
        )
        let healthyConnection = try await openConnection(
            to: 12_345,
            through: session,
            pipe: pipe,
            deviceSequenceNumber: 70
        )

        let payload = Data(
            repeating: 0xaa,
            count: 65_000
        )
        var sequenceNumber: UInt32 = 51
        for transmitSequence in UInt16(5)...UInt16(134) {
            try await pipe.enqueueRead(
                muxPacket(
                    tcpPacket: DirectUSBMuxTCPPacket(
                        sourcePort: overflowingConnection.remotePort,
                        destinationPort: overflowingConnection.localPort,
                        sequenceNumber: sequenceNumber,
                        acknowledgmentNumber: 1,
                        flags: [.acknowledgment],
                        windowSize: 512,
                        payload: payload
                    ),
                    transmitSequence: transmitSequence
                )
            )
            sequenceNumber &+= UInt32(payload.count)
            if transmitSequence < 134 {
                _ = try await nextTCPPacket(from: pipe)
            }
        }

        let reset = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(reset.flags, [.reset])
        do {
            _ = try await overflowingConnection.receive(upTo: 1)
            XCTFail("Expected the overflowing connection to fail.")
        } catch let error as DirectUSBMuxError {
            XCTAssertEqual(
                error,
                .receiveBufferOverflow(
                    localPort: overflowingConnection.localPort,
                    maximumByteCount: 8 * 1_024 * 1_024
                )
            )
        }

        try await healthyConnection.send(Data([0xbb]))
        let healthyPacket = try await nextTCPPacket(from: pipe)
        XCTAssertEqual(healthyPacket.payload, Data([0xbb]))

        healthyConnection.close()
        await session.close()
    }
}

extension DirectUSBMuxSessionTests {
    fileprivate func openSession(
        over pipe: DirectUSBMuxTestPipe
    ) async throws -> DirectUSBMuxSession {
        let openTask = Task {
            try await DirectUSBMuxSession.open(
                over: pipe,
                outboundUSBPacketSize: 512,
                handshakeTimeout: .seconds(1),
                connectionTimeout: .seconds(1)
            )
        }

        var legacyDecoder = DirectUSBMuxPacketDecoder(
            headerFormat: .legacy
        )
        legacyDecoder.append(await pipe.nextWrite())
        let versionRequest = try XCTUnwrap(
            try legacyDecoder.nextPacket()
        )
        XCTAssertEqual(versionRequest.protocol, .version)
        XCTAssertEqual(
            versionRequest.payload,
            Data([
                0, 0, 0, 2,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ])
        )

        let codec = DirectUSBMuxPacketCodec()
        try await pipe.enqueueRead(
            codec.encode(
                protocol: .version,
                payload: Data([
                    0, 0, 0, 2,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                ]),
                header: .legacy
            )
        )

        var sequencedDecoder = DirectUSBMuxPacketDecoder(
            headerFormat: .sequenced
        )
        sequencedDecoder.append(await pipe.nextWrite())
        let setup = try XCTUnwrap(
            try sequencedDecoder.nextPacket()
        )
        XCTAssertEqual(setup.protocol, .setup)
        XCTAssertEqual(setup.payload, Data([0x07]))
        XCTAssertEqual(
            setup.header,
            .sequenced(
                transmitSequence: 0,
                receiveSequence: 0xffff
            )
        )

        return try await openTask.value
    }

    fileprivate func openConnection(
        to remotePort: UInt16,
        through session: DirectUSBMuxSession,
        pipe: DirectUSBMuxTestPipe,
        deviceSequenceNumber: UInt32
    ) async throws -> DirectUSBMuxConnection {
        let connectTask = Task {
            try await session.connect(to: remotePort)
        }
        let syn = try await nextTCPPacket(from: pipe)
        try await pipe.enqueueRead(
            muxPacket(
                tcpPacket: DirectUSBMuxTCPPacket(
                    sourcePort: remotePort,
                    destinationPort: syn.sourcePort,
                    sequenceNumber: deviceSequenceNumber,
                    acknowledgmentNumber: 1,
                    flags: [.synchronize, .acknowledgment],
                    windowSize: 512,
                    payload: Data()
                ),
                transmitSequence: 1
            )
        )
        _ = try await nextTCPPacket(from: pipe)
        return try await connectTask.value
    }

    fileprivate func nextTCPPacket(
        from pipe: DirectUSBMuxTestPipe
    ) async throws -> DirectUSBMuxTCPPacket {
        let packet = try await nextMuxPacket(from: pipe)
        XCTAssertEqual(packet.protocol, .tcp)
        return try DirectUSBMuxTCPPacket.decode(packet.payload)
    }

    fileprivate func nextMuxPacket(
        from pipe: DirectUSBMuxTestPipe
    ) async throws -> DirectUSBMuxPacket {
        var decoder = DirectUSBMuxPacketDecoder(
            headerFormat: .sequenced
        )
        decoder.append(await pipe.nextWrite())
        return try XCTUnwrap(try decoder.nextPacket())
    }

    fileprivate func decodeTCPPacket(
        _ data: Data
    ) throws -> DirectUSBMuxTCPPacket {
        var decoder = DirectUSBMuxPacketDecoder(
            headerFormat: .sequenced
        )
        decoder.append(data)
        let packet = try XCTUnwrap(try decoder.nextPacket())
        XCTAssertEqual(packet.protocol, .tcp)
        return try DirectUSBMuxTCPPacket.decode(packet.payload)
    }

    fileprivate func muxPacket(
        tcpPacket: DirectUSBMuxTCPPacket,
        transmitSequence: UInt16,
        receiveSequence: UInt16? = nil
    ) throws -> Data {
        try DirectUSBMuxPacketCodec().encode(
            protocol: .tcp,
            payload: tcpPacket.encoded(),
            header: .sequenced(
                transmitSequence: transmitSequence,
                receiveSequence: receiveSequence ?? transmitSequence
            )
        )
    }
}

private actor DirectUSBMuxTestPipe: DirectUSBMuxIO {
    private struct SuspendedWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Never>
    }

    private var reads: [Data] = []
    private var writes: [Data] = []
    private var readWaiter: CheckedContinuation<Data, Error>?
    private var writeWaiter: CheckedContinuation<Data, Never>?
    private var suspendedWrite: SuspendedWrite?
    private var suspendedWriteWaiter: CheckedContinuation<Data, Never>?
    private var shouldSuspendNextWrite = false
    private var isClosed = false

    func read(upTo byteCount: Int) async throws -> Data {
        if !reads.isEmpty {
            return reads.removeFirst()
        }
        if isClosed {
            throw DirectUSBMuxError.transportClosed
        }
        return try await withCheckedThrowingContinuation {
            readWaiter = $0
        }
    }

    func write(_ data: Data) async throws {
        if isClosed {
            throw DirectUSBMuxError.transportClosed
        }
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            await withCheckedContinuation { continuation in
                suspendedWrite = SuspendedWrite(
                    data: data,
                    continuation: continuation
                )
                if let suspendedWriteWaiter {
                    self.suspendedWriteWaiter = nil
                    suspendedWriteWaiter.resume(returning: data)
                }
            }
            return
        }
        if let writeWaiter {
            self.writeWaiter = nil
            writeWaiter.resume(returning: data)
        } else {
            writes.append(data)
        }
    }

    func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        let readWaiter = self.readWaiter
        self.readWaiter = nil
        readWaiter?.resume(
            throwing: DirectUSBMuxError.transportClosed
        )
    }

    func enqueueRead(_ data: Data) throws {
        guard !isClosed else {
            throw DirectUSBMuxError.transportClosed
        }
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: data)
        } else {
            reads.append(data)
        }
    }

    func nextWrite() async -> Data {
        if !writes.isEmpty {
            return writes.removeFirst()
        }
        return await withCheckedContinuation {
            writeWaiter = $0
        }
    }

    func takeWrites() -> [Data] {
        defer {
            writes.removeAll()
        }
        return writes
    }

    func suspendNextWrite() {
        precondition(
            suspendedWrite == nil && !shouldSuspendNextWrite,
            "Only one test write may be suspended at a time."
        )
        shouldSuspendNextWrite = true
    }

    func nextSuspendedWrite() async -> Data {
        if let suspendedWrite {
            return suspendedWrite.data
        }
        return await withCheckedContinuation {
            suspendedWriteWaiter = $0
        }
    }

    func resumeSuspendedWrite() {
        guard let suspendedWrite else {
            preconditionFailure("No test write is suspended.")
        }
        self.suspendedWrite = nil
        suspendedWrite.continuation.resume()
    }
}
