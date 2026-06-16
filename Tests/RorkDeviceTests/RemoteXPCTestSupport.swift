import Foundation
@testable import RorkDevice

/// Encodes one HTTP/2 frame for RemoteXPC protocol fixtures.
///
/// Tests use this helper to keep byte-level stream identifiers visible while
/// avoiding repeated 24-bit length and reserved-bit framing logic.
func remoteXPCTestFrame(
    type: UInt8,
    flags: UInt8 = 0,
    streamIdentifier: UInt32,
    payload: some DataProtocol = Data()
) -> Data {
    let payload = Data(payload)
    var frame = Data([
        UInt8((payload.count >> 16) & 0xff),
        UInt8((payload.count >> 8) & 0xff),
        UInt8(payload.count & 0xff),
        type,
        flags,
    ])
    frame.appendBigEndian(streamIdentifier)
    frame.append(payload)
    return frame
}

/// Builds the peer traffic required to complete RemoteXPC channel startup.
///
/// The device first advertises HTTP/2 settings, then acknowledges the host's
/// three message-zero initialization requests on the control, reply, and
/// control streams respectively. Service-specific fixtures append their first
/// application message after these frames.
func remoteXPCSessionHandshakeInbound() throws -> Data {
    let acknowledgement = try RemoteXPCMessageCodec.encode(
        value: nil,
        flags: 0x00000001,
        messageIdentifier: 0
    )
    var inbound = remoteXPCTestFrame(
        type: 0x04,
        streamIdentifier: 0
    )
    for streamIdentifier: UInt32 in [1, 3, 1] {
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: streamIdentifier,
                payload: acknowledgement
            )
        )
    }
    return inbound
}
