import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingControlChannelTests: XCTestCase {
    func testRemoteXPCChannelUsesBinaryPayloadsAndStartsAtSequenceOne() async throws {
        let devicePairingData = Data([0x11, 0x22, 0x33])
        let responseEnvelope = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "mangledTypeName": .string(
                    "RemotePairing.ControlChannelMessageEnvelope"
                ),
                "value": .dictionary([
                    "message": .dictionary([
                        "plain": .dictionary([
                            "_0": .dictionary([
                                "event": .dictionary([
                                    "_0": .dictionary([
                                        "pairingData": .dictionary([
                                            "_0": .dictionary([
                                                "data": .data(
                                                    devicePairingData
                                                ),
                                            ]),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    "originatedBy": .string("device"),
                    "sequenceNumber": .uint64(1),
                ]),
            ]),
            flags: 0x00000101,
            messageIdentifier: 1
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: responseEnvelope
            )
        )
        let connection = FakeConnection(inbound: inbound)
        let channel = try await RemotePairingRemoteXPCChannel.open(
            over: connection
        )
        let hostPairingData = Data([0xaa, 0xbb, 0xcc])

        try await channel.sendPlain([
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": [
                            "data": hostPairingData,
                        ],
                    ],
                ],
            ],
        ])
        let response = try await channel.receivePlain()

        XCTAssertEqual(
            pairingControlNestedValue(
                response,
                keys: ["event", "_0", "pairingData", "_0", "data"]
            ) as? Data,
            devicePairingData
        )

        let requestFrame = try XCTUnwrap(
            connection.sent.reversed().first { frame in
                guard frame.count >= 9, frame[3] == 0x00 else {
                    return false
                }
                return Data(frame[5...8]) == Data([0, 0, 0, 1])
            }
        )
        let request = try XCTUnwrap(
            RemoteXPCMessageCodec.decodeFirstMessage(
                from: Data(requestFrame.dropFirst(9))
            )
        ).message
        guard case let .dictionary(root)? = request.value,
              case let .dictionary(value)? = root["value"],
              case let .uint64(sequenceNumber)? = value["sequenceNumber"],
              case let .dictionary(message)? = value["message"],
              case let .dictionary(plain)? = message["plain"],
              case let .dictionary(payload)? = plain["_0"],
              case let .dictionary(event)? = payload["event"],
              case let .dictionary(eventPayload)? = event["_0"],
              case let .dictionary(pairingData)? = eventPayload["pairingData"],
              case let .dictionary(pairingPayload)? = pairingData["_0"] else {
            return XCTFail("Remote-pairing request envelope is malformed.")
        }

        XCTAssertEqual(sequenceNumber, 1)
        XCTAssertEqual(pairingPayload["data"], .data(hostPairingData))
    }
}

private func pairingControlNestedValue(
    _ dictionary: [String: Any],
    keys: [String]
) -> Any? {
    var value: Any = dictionary
    for key in keys {
        guard let current = value as? [String: Any],
              let next = current[key] else {
            return nil
        }
        value = next
    }
    return value
}
