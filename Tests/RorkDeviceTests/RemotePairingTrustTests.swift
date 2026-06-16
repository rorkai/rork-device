import CryptoKit
import Foundation
import XCTest
@testable import RorkDevice

final class RemotePairingTrustTests: XCTestCase {
    func testClosesTheControlConnectionAfterVerifyingTrust() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let identity = RemotePairingIdentity(
            identifier: "test-host",
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x7a, count: 16)
        )
        let deviceAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        var inbound = Data()
        inbound.append(try trustFrame(plain: [
            "response": [
                "_1": [
                    "handshake": [
                        "_0": [:],
                    ],
                ],
            ],
        ]))
        inbound.append(try trustPairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x02])),
            TLV8Field(
                type: 0x03,
                value: deviceAgreementKey.publicKey.rawRepresentation
            ),
        ])))
        inbound.append(try trustPairingFrame(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x04])),
        ])))
        let connection = FakeConnection(inbound: inbound)

        try await RemotePairingTrust.establishIfNeeded(
            for: identity,
            openConnection: { connection }
        )

        XCTAssertTrue(connection.isClosed)
    }

    func testEstablishesTrustThroughTheUntrustedRemoteXPCService() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let identity = RemotePairingIdentity(
            identifier: "test-host",
            privateKey: signingKey,
            identityResolvingKey: Data(repeating: 0x7a, count: 16)
        )
        let deviceAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let discoveryPort: UInt16 = 54_130
        let pairingServicePort: UInt16 = 63_795
        let discoveryConnection = FakeConnection(
            inbound: try trustDiscoveryWire(
                servicePort: pairingServicePort
            )
        )
        let pairingConnection = FakeConnection(
            inbound: try trustRemoteXPCWire([
                .dictionary([
                    "response": .dictionary([
                        "_1": .dictionary([
                            "handshake": .dictionary([
                                "_0": .dictionary([:]),
                            ]),
                        ]),
                    ]),
                ]),
                trustRemoteXPCPairingEvent(TLV8.encode([
                    TLV8Field(type: 0x06, value: Data([0x02])),
                    TLV8Field(
                        type: 0x03,
                        value: deviceAgreementKey.publicKey.rawRepresentation
                    ),
                ])),
                trustRemoteXPCPairingEvent(TLV8.encode([
                    TLV8Field(type: 0x06, value: Data([0x04])),
                ])),
            ])
        )
        let transport = PortRoutingDeviceTransport(connections: [
            discoveryPort: discoveryConnection,
            pairingServicePort: pairingConnection,
        ])
        let progress = TrustProgressRecorder()

        try await RemotePairingTrust.establishIfNeeded(
            for: identity,
            using: transport,
            discoveryPort: discoveryPort,
            progress: progress.record
        )

        XCTAssertEqual(
            transport.requestedPorts,
            [discoveryPort, pairingServicePort]
        )
        XCTAssertEqual(progress.values, [
            .openingServiceDiscovery,
            .openingPairingService,
            .verifyingIdentity,
            .established,
        ])
        XCTAssertTrue(discoveryConnection.isClosed)
        XCTAssertTrue(pairingConnection.isClosed)
    }
}

private final class TrustProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [RemotePairingTrust.Progress] = []

    var values: [RemotePairingTrust.Progress] {
        lock.withLock { recordedValues }
    }

    func record(_ progress: RemotePairingTrust.Progress) {
        lock.withLock {
            recordedValues.append(progress)
        }
    }
}

/// Routes requested device ports to deterministic in-memory connections.
private final class PortRoutingDeviceTransport: DeviceTransport {
    /// Connections supplied by the test, keyed by their device-side port.
    private var connections: [UInt16: DeviceConnection]

    /// Ports requested by the API in call order.
    private(set) var requestedPorts: [UInt16] = []

    /// Creates a transport with one connection for every expected service port.
    init(connections: [UInt16: DeviceConnection]) {
        self.connections = connections
    }

    /// Returns and consumes the connection assigned to `port`.
    func connect(to port: UInt16) async throws -> DeviceConnection {
        requestedPorts.append(port)
        guard let connection = connections.removeValue(forKey: port) else {
            throw RorkDeviceError.invalidInput(
                "Unexpected test port \(port)."
            )
        }
        return connection
    }
}

private func trustFrame(plain: [String: Any]) throws -> Data {
    try RemotePairingFrameCodec.encode([
        "message": [
            "plain": [
                "_0": plain,
            ],
        ],
    ])
}

private func trustPairingFrame(_ pairingData: Data) throws -> Data {
    try trustFrame(plain: [
        "event": [
            "_0": [
                "pairingData": [
                    "_0": [
                        "data": pairingData.base64EncodedString(),
                    ],
                ],
            ],
        ],
    ])
}

private func trustDiscoveryWire(servicePort: UInt16) throws -> Data {
    let handshake = try RemoteXPCMessageCodec.encode(
        value: .dictionary([
            "MessageType": .string("Handshake"),
            "Properties": .dictionary([
                "UniqueDeviceID": .string("device-1"),
            ]),
            "Services": .dictionary([
                "com.apple.internal.dt.coredevice.untrusted.tunnelservice":
                    .dictionary([
                        "Port": .uint64(UInt64(servicePort)),
                    ]),
            ]),
        ]),
        flags: 0x00000101,
        messageIdentifier: 1
    )
    var wire = try remoteXPCSessionHandshakeInbound()
    wire.append(
        remoteXPCTestFrame(
            type: 0x00,
            streamIdentifier: 1,
            payload: handshake
        )
    )
    return wire
}

private func trustRemoteXPCWire(
    _ messages: [RemoteXPCValue]
) throws -> Data {
    var wire = try remoteXPCSessionHandshakeInbound()
    for (index, message) in messages.enumerated() {
        let envelope = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "mangledTypeName": .string(
                    "RemotePairing.ControlChannelMessageEnvelope"
                ),
                "value": .dictionary([
                    "message": .dictionary([
                        "plain": .dictionary([
                            "_0": message,
                        ]),
                    ]),
                    "originatedBy": .string("device"),
                    "sequenceNumber": .uint64(UInt64(index + 1)),
                ]),
            ]),
            flags: 0x00000101,
            messageIdentifier: UInt64(index + 1)
        )
        wire.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 1,
                payload: envelope
            )
        )
    }
    return wire
}

private func trustRemoteXPCPairingEvent(
    _ pairingData: Data
) -> RemoteXPCValue {
    .dictionary([
        "event": .dictionary([
            "_0": .dictionary([
                "pairingData": .dictionary([
                    "_0": .dictionary([
                        "data": .data(pairingData),
                    ]),
                ]),
            ]),
        ]),
    ])
}
