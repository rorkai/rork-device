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
}
