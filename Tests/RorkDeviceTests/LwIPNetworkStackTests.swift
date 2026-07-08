import Foundation
import XCTest
@testable import RorkDevice

final class LwIPNetworkStackTests: XCTestCase {
    func testCancelsConnectionTimeoutAfterHandshakeSucceeds() async throws {
        let timeoutStarted = expectation(
            description: "Connection timeout task started."
        )
        let timeoutCancelled = expectation(
            description: "Connection timeout task was cancelled."
        )
        let state = LwIPConnectionState { _ in
            timeoutStarted.fulfill()
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
            } onCancel: {
                timeoutCancelled.fulfill()
            }
        }
        let connectionTask = Task {
            try await state.waitUntilConnected(timeout: .seconds(30))
        }
        await fulfillment(of: [timeoutStarted], timeout: 1)

        state.handleConnected()

        try await connectionTask.value
        await fulfillment(of: [timeoutCancelled], timeout: 1)
    }

    func testConnectionUsesItsOwningInterfaceWhenAddressesOverlap() async throws {
        let firstPackets = LwIPPacketRecorder()
        let secondPackets = LwIPPacketRecorder()
        let firstStack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 1_280
        ) { packet in
            firstPackets.append(packet)
        }
        let secondStack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 1_280
        ) { packet in
            secondPackets.append(packet)
        }
        let connectionTask = Task {
            try await firstStack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .seconds(2)
            )
        }

        do {
            _ = try await firstPackets.waitForPacket {
                tcpFlags(in: $0).contains(.synchronize)
            }
            XCTAssertEqual(secondPackets.count, 0)
        } catch {
            firstStack.close()
            secondStack.close()
            _ = try? await connectionTask.value
            throw error
        }

        firstStack.close()
        secondStack.close()
        _ = try? await connectionTask.value
    }

    func testSendingAfterClosingConnectionFails() async throws {
        let packets = LwIPPacketRecorder()
        let stack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 1_280
        ) { packet in
            packets.append(packet)
        }
        defer {
            stack.close()
        }

        let connectionTask = Task {
            try await stack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .seconds(2)
            )
        }
        let syn = try await packets.waitForPacket {
            tcpFlags(in: $0).contains(.synchronize)
        }
        try await stack.receivePacket(
            tcpPacket(
                sourceAddress: ipv6Bytes("fd00::1"),
                destinationAddress: ipv6Bytes("fd00::2"),
                sourcePort: tcpDestinationPort(in: syn),
                destinationPort: tcpSourcePort(in: syn),
                sequenceNumber: 0x1020_3040,
                acknowledgmentNumber: tcpSequenceNumber(in: syn) &+ 1,
                flags: [.synchronize, .acknowledgment]
            )
        )
        let connection = try await connectionTask.value
        connection.close()

        do {
            try await connection.send(Data("closed".utf8))
            XCTFail("Sending through a closed lwIP connection should fail.")
        } catch {}
    }

    func testSYNAdvertisesJumboMSSAndOffersWindowScaling() async throws {
        let packets = LwIPPacketRecorder()
        let stack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 16_000
        ) { packet in
            packets.append(packet)
        }
        defer {
            stack.close()
        }

        let connectionTask = Task {
            try? await stack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .milliseconds(200)
            )
        }
        defer {
            connectionTask.cancel()
        }
        let syn = try await packets.waitForPacket {
            tcpFlags(in: $0).contains(.synchronize)
        }

        // A 16,000-byte MTU leaves 15,940 bytes after the IPv6 and TCP
        // headers. The window-scale option must be offered too, because
        // without it the receive window cannot grow past 64 KB.
        XCTAssertEqual(tcpOptionValue(in: syn, kind: 2), 15_940)
        XCTAssertNotNil(tcpOptionValue(in: syn, kind: 3))
        _ = await connectionTask.value
    }

    func testSYNClampsAdvertisedMSSToTheGrantedMTU() async throws {
        let packets = LwIPPacketRecorder()
        let stack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 1_280
        ) { packet in
            packets.append(packet)
        }
        defer {
            stack.close()
        }

        let connectionTask = Task {
            try? await stack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .milliseconds(200)
            )
        }
        defer {
            connectionTask.cancel()
        }
        let syn = try await packets.waitForPacket {
            tcpFlags(in: $0).contains(.synchronize)
        }

        // A device that grants only the IPv6 minimum MTU must see segment
        // sizes that fit inside 1,280-byte packets, jumbo build or not.
        XCTAssertEqual(tcpOptionValue(in: syn, kind: 2), 1_220)
        _ = await connectionTask.value
    }

    func testBulkSendMovesDataWithTheScaledSendBuffer() async throws {
        // Window scaling makes the send buffer a 32-bit quantity. The C
        // shim used to read it into a u16, which turned a full one-megabyte
        // buffer into zero capacity and stalled every bulk send.
        let packets = LwIPPacketRecorder()
        let stack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 16_000
        ) { packet in
            packets.append(packet)
        }
        defer {
            stack.close()
        }

        let connectionTask = Task {
            try await stack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .seconds(2)
            )
        }
        let syn = try await packets.waitForPacket {
            tcpFlags(in: $0).contains(.synchronize)
        }
        try await stack.receivePacket(
            tcpPacket(
                sourceAddress: ipv6Bytes("fd00::1"),
                destinationAddress: ipv6Bytes("fd00::2"),
                sourcePort: tcpDestinationPort(in: syn),
                destinationPort: tcpSourcePort(in: syn),
                sequenceNumber: 0x0102_0304,
                acknowledgmentNumber: tcpSequenceNumber(in: syn) &+ 1,
                flags: [.synchronize, .acknowledgment]
            )
        )
        let connection = try await connectionTask.value
        defer {
            connection.close()
        }

        // 200 KB does not fit in any 16-bit reading of the send buffer, so
        // this send hangs when the truncation bug is present. The race with
        // the timer keeps a regression from hanging the whole suite.
        let payload = Data(repeating: 0xAB, count: 200_000)
        let outcome = await withThrowingTaskGroup(
            of: Bool.self
        ) { group -> Bool in
            group.addTask {
                try await connection.send(payload)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            defer {
                group.cancelAll()
            }
            return (try? await group.next()) ?? false
        }
        XCTAssertTrue(outcome, "Bulk send stalled with the scaled send buffer")
    }

    func testConnectsAndExchangesTCPPayloadsOverIPv6Packets() async throws {
        let packets = LwIPPacketRecorder()
        let stack = try LwIPNetworkStack(
            localAddress: "fd00::2",
            maximumTransmissionUnit: 1_280
        ) { packet in
            packets.append(packet)
        }
        defer {
            stack.close()
        }

        let connectionTask = Task {
            try await stack.connect(
                to: "fd00::1",
                port: 58_783,
                timeout: .seconds(2)
            )
        }
        let syn = try await packets.waitForPacket {
            tcpFlags(in: $0).contains(.synchronize)
        }
        XCTAssertEqual(ipv6SourceAddress(in: syn), ipv6Bytes("fd00::2"))
        XCTAssertEqual(
            ipv6DestinationAddress(in: syn),
            ipv6Bytes("fd00::1")
        )
        XCTAssertEqual(tcpDestinationPort(in: syn), 58_783)

        let remoteInitialSequence: UInt32 = 0x1020_3040
        try await stack.receivePacket(
            tcpPacket(
                sourceAddress: ipv6Bytes("fd00::1"),
                destinationAddress: ipv6Bytes("fd00::2"),
                sourcePort: tcpDestinationPort(in: syn),
                destinationPort: tcpSourcePort(in: syn),
                sequenceNumber: remoteInitialSequence,
                acknowledgmentNumber: tcpSequenceNumber(in: syn) &+ 1,
                flags: [.synchronize, .acknowledgment]
            )
        )
        let connection = try await connectionTask.value
        defer {
            connection.close()
        }

        let outputStart = packets.count
        try await connection.send(Data("hello".utf8))
        let outbound = try await packets.waitForPacket(
            after: outputStart
        ) {
            tcpPayload(in: $0) == Data("hello".utf8)
        }
        XCTAssertEqual(
            tcpAcknowledgmentNumber(in: outbound),
            remoteInitialSequence &+ 1
        )

        let outboundPayload = tcpPayload(in: outbound)
        try await stack.receivePacket(
            tcpPacket(
                sourceAddress: ipv6Bytes("fd00::1"),
                destinationAddress: ipv6Bytes("fd00::2"),
                sourcePort: tcpDestinationPort(in: outbound),
                destinationPort: tcpSourcePort(in: outbound),
                sequenceNumber: remoteInitialSequence &+ 1,
                acknowledgmentNumber:
                    tcpSequenceNumber(in: outbound)
                    &+ UInt32(outboundPayload.count),
                flags: [.push, .acknowledgment],
                payload: Data("world".utf8)
            )
        )

        let received = try await connection.receive(exactly: 5)
        XCTAssertEqual(received, Data("world".utf8))
    }
}

private final class LwIPPacketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    var count: Int {
        lock.withLock { packets.count }
    }

    func append(_ packet: Data) {
        lock.withLock {
            packets.append(packet)
        }
    }

    func waitForPacket(
        after index: Int = 0,
        matching predicate: @escaping (Data) -> Bool
    ) async throws -> Data {
        for _ in 0..<400 {
            if let packet = lock.withLock({
                packets.dropFirst(index).first(where: predicate)
            }) {
                return packet
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RorkDeviceError.transport(
            "Timed out waiting for an lwIP test packet."
        )
    }
}

private struct TCPFlags: OptionSet {
    let rawValue: UInt8

    static let finish = TCPFlags(rawValue: 0x01)
    static let synchronize = TCPFlags(rawValue: 0x02)
    static let reset = TCPFlags(rawValue: 0x04)
    static let push = TCPFlags(rawValue: 0x08)
    static let acknowledgment = TCPFlags(rawValue: 0x10)
}

private func ipv6Bytes(_ address: String) -> Data {
    try! ipv6AddressBytes(address, invalidMessage: "Invalid test address.")
}

private func ipv6SourceAddress(in packet: Data) -> Data {
    Data(packet[8..<24])
}

private func ipv6DestinationAddress(in packet: Data) -> Data {
    Data(packet[24..<40])
}

private func tcpSourcePort(in packet: Data) -> UInt16 {
    try! packet.bigEndianInteger(at: 40, as: UInt16.self)
}

private func tcpDestinationPort(in packet: Data) -> UInt16 {
    try! packet.bigEndianInteger(at: 42, as: UInt16.self)
}

private func tcpSequenceNumber(in packet: Data) -> UInt32 {
    try! packet.bigEndianInteger(at: 44, as: UInt32.self)
}

private func tcpAcknowledgmentNumber(in packet: Data) -> UInt32 {
    try! packet.bigEndianInteger(at: 48, as: UInt32.self)
}

private func tcpFlags(in packet: Data) -> TCPFlags {
    TCPFlags(rawValue: packet[53])
}

private func tcpPayload(in packet: Data) -> Data {
    let headerLength = Int(packet[52] >> 4) * 4
    return Data(packet.dropFirst(40 + headerLength))
}

/// Reads one TCP option's value from a segment, or nil when absent.
///
/// The MSS option (kind 2) yields its 16-bit value. The window-scale option
/// (kind 3) yields the shift count. Options without a value yield zero when
/// present.
private func tcpOptionValue(in packet: Data, kind: UInt8) -> Int? {
    let headerLength = Int(packet[52] >> 4) * 4
    let options = Data(packet.dropFirst(60).prefix(headerLength - 20))
    var index = 0
    while index < options.count {
        let optionKind = options[options.startIndex + index]
        if optionKind == 0 {
            return nil
        }
        if optionKind == 1 {
            index += 1
            continue
        }
        guard index + 1 < options.count else {
            return nil
        }
        let length = Int(options[options.startIndex + index + 1])
        guard length >= 2, index + length <= options.count else {
            return nil
        }
        if optionKind == kind {
            let payload = options.dropFirst(index + 2).prefix(length - 2)
            return payload.reduce(0) { ($0 << 8) | Int($1) }
        }
        index += length
    }
    return nil
}

private func tcpPacket(
    sourceAddress: Data,
    destinationAddress: Data,
    sourcePort: UInt16,
    destinationPort: UInt16,
    sequenceNumber: UInt32,
    acknowledgmentNumber: UInt32,
    flags: TCPFlags,
    payload: Data = Data()
) -> Data {
    var tcp = Data()
    tcp.appendBigEndian(sourcePort)
    tcp.appendBigEndian(destinationPort)
    tcp.appendBigEndian(sequenceNumber)
    tcp.appendBigEndian(acknowledgmentNumber)
    tcp.append(5 << 4)
    tcp.append(flags.rawValue)
    tcp.appendBigEndian(UInt16.max)
    tcp.appendBigEndian(UInt16(0))
    tcp.appendBigEndian(UInt16(0))
    tcp.append(payload)

    var pseudoHeader = sourceAddress + destinationAddress
    pseudoHeader.appendBigEndian(UInt32(tcp.count))
    pseudoHeader.append(contentsOf: [0, 0, 0, 6])
    let checksum = internetChecksum(pseudoHeader + tcp)
    tcp[16] = UInt8(checksum >> 8)
    tcp[17] = UInt8(checksum & 0xff)

    var ipv6 = Data(repeating: 0, count: 40)
    ipv6[0] = 0x60
    ipv6[4] = UInt8(tcp.count >> 8)
    ipv6[5] = UInt8(tcp.count & 0xff)
    ipv6[6] = 6
    ipv6[7] = 64
    ipv6.replaceSubrange(8..<24, with: sourceAddress)
    ipv6.replaceSubrange(24..<40, with: destinationAddress)
    return ipv6 + tcp
}

private func internetChecksum(_ data: Data) -> UInt16 {
    var sum: UInt32 = 0
    var index = data.startIndex
    while index < data.endIndex {
        let high = UInt16(data[index]) << 8
        index = data.index(after: index)
        let low: UInt16
        if index < data.endIndex {
            low = UInt16(data[index])
            index = data.index(after: index)
        } else {
            low = 0
        }
        sum += UInt32(high | low)
        while sum > UInt32(UInt16.max) {
            sum = (sum & UInt32(UInt16.max)) + (sum >> 16)
        }
    }
    return ~UInt16(sum)
}
