import Foundation
import XCTest
@testable import RorkDevice

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RemotePairingTrustTests: XCTestCase {
    func testClosesTheControlConnectionAfterVerifyingTrust() async throws {
        let identity = makeTrustIdentity()
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
        let identity = makeTrustIdentity()
        let deviceAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let discoveryConnection = FakeConnection(
            inbound: try trustDiscoveryWire(
                servicePort: TrustTestPort.pairingService
            )
        )
        let pairingConnection = FakeConnection(
            inbound: try trustVerificationWire(
                deviceAgreementKey: deviceAgreementKey,
                finalFields: [
                    TLV8Field(type: 0x06, value: Data([0x04])),
                ]
            )
        )
        let transport = PortRoutingDeviceTransport(connections: [
            TrustTestPort.discovery: discoveryConnection,
            TrustTestPort.pairingService: pairingConnection,
        ])
        let progress = TrustProgressRecorder()

        try await RemotePairingTrust.establishIfNeeded(
            for: identity,
            using: transport,
            discoveryPort: TrustTestPort.discovery,
            progress: progress.record
        )

        XCTAssertEqual(
            transport.requestedPorts,
            [TrustTestPort.discovery, TrustTestPort.pairingService]
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

    func testVerifiesTheSameIdentityOnAFreshSessionAfterEnrollmentStarts()
        async throws
    {
        let progress = TrustProgressRecorder()
        let attempts = TrustAttemptRecorder()

        try await RemotePairingTrust.establishWithRecovery(
            progress: progress.record,
            verificationAttemptDelays: [.zero],
            sleep: { _ in },
            initialAttempt: { willBeginEnrollment in
                attempts.recordInitialAttempt()
                willBeginEnrollment()
            },
            verificationAttempt: {
                attempts.recordVerificationAttempt()
            }
        )

        XCTAssertEqual(attempts.initialAttempts, 1)
        XCTAssertEqual(attempts.verificationAttempts, 1)
        XCTAssertEqual(progress.values, [
            .enrollingIdentity,
            .established,
        ])
    }

    func testDoesNotRecoverAStreamResetBeforeEnrollmentBegins()
        async throws
    {
        let identity = makeTrustIdentity()
        let transport = PortRoutingDeviceTransport(connections: [
            TrustTestPort.discovery: FakeConnection(
                inbound: try trustDiscoveryWire(
                    servicePort: TrustTestPort.pairingService
                )
            ),
            TrustTestPort.pairingService: FakeConnection(
                inbound: try trustPreEnrollmentResetWire()
            ),
        ])
        let progress = TrustProgressRecorder()

        do {
            try await RemotePairingTrust.establishIfNeeded(
                for: identity,
                discoveryPort: TrustTestPort.discovery,
                progress: progress.record,
                openConnection: transport.connect
            )
            XCTFail("Expected the initial verification stream reset to fail.")
        } catch {
            XCTAssertEqual(
                error as? RorkDeviceError,
                .remoteXPCStreamReset(
                    streamIdentifier: 1,
                    errorCode: 0x08
                )
            )
        }

        XCTAssertEqual(
            transport.requestedPorts,
            [TrustTestPort.discovery, TrustTestPort.pairingService]
        )
        XCTAssertEqual(progress.values, [
            .openingServiceDiscovery,
            .openingPairingService,
            .verifyingIdentity,
        ])
    }

    func testVerifiesAfterEnrollmentStartsWhenSetupStreamResetsBeforeM6()
        async throws
    {
        let progress = TrustProgressRecorder()
        let attempts = TrustAttemptRecorder()
        let attemptDelays = TrustAttemptDelayRecorder()
        let resetError = RorkDeviceError.remoteXPCStreamReset(
            streamIdentifier: 1,
            errorCode: 0x08
        )

        try await RemotePairingTrust.establishWithRecovery(
            progress: progress.record,
            verificationAttemptDelays: [
                .zero,
                .milliseconds(25),
            ],
            sleep: { duration in
                await attemptDelays.record(duration)
            },
            initialAttempt: { willBeginEnrollment in
                attempts.recordInitialAttempt()
                willBeginEnrollment()
                throw resetError
            },
            verificationAttempt: {
                let attempt = attempts.recordVerificationAttempt()
                if attempt == 1 {
                    throw RorkDeviceError.remotePairing(.unknownPeer)
                }
            }
        )

        XCTAssertEqual(attempts.initialAttempts, 1)
        XCTAssertEqual(attempts.verificationAttempts, 2)
        XCTAssertEqual(progress.values, [
            .enrollingIdentity,
            .established,
        ])
        let recordedAttemptDelays = await attemptDelays.values
        XCTAssertEqual(recordedAttemptDelays, [.milliseconds(25)])
    }

    func testRetriesTransportFailureAfterEnrollmentStartsWithoutRepeatingEnrollment()
        async throws
    {
        let progress = TrustProgressRecorder()
        let attempts = TrustAttemptRecorder()
        let attemptDelays = TrustAttemptDelayRecorder()

        try await RemotePairingTrust.establishWithRecovery(
            progress: progress.record,
            verificationAttemptDelays: [
                .zero,
                .milliseconds(25),
            ],
            sleep: { duration in
                await attemptDelays.record(duration)
            },
            initialAttempt: { willBeginEnrollment in
                attempts.recordInitialAttempt()
                willBeginEnrollment()
                throw RorkDeviceError.transport(
                    "The enrollment stream closed."
                )
            },
            verificationAttempt: {
                let attempt = attempts.recordVerificationAttempt()
                if attempt == 1 {
                    throw RorkDeviceError.remotePairing(.unknownPeer)
                }
            }
        )

        XCTAssertEqual(attempts.initialAttempts, 1)
        XCTAssertEqual(attempts.verificationAttempts, 2)
        XCTAssertEqual(progress.values, [
            .enrollingIdentity,
            .established,
        ])
        let recordedAttemptDelays = await attemptDelays.values
        XCTAssertEqual(recordedAttemptDelays, [.milliseconds(25)])
    }

    func testDoesNotMaskNonRetryableFailuresAfterEnrollmentStarts()
        async throws
    {
        let attempts = TrustAttemptRecorder()
        let protocolError = RorkDeviceError.protocolViolation(
            "The remote-unlock response is malformed."
        )

        do {
            try await RemotePairingTrust.establishWithRecovery(
                progress: { _ in },
                verificationAttemptDelays: [.zero],
                sleep: { _ in },
                initialAttempt: { willBeginEnrollment in
                    attempts.recordInitialAttempt()
                    willBeginEnrollment()
                    throw protocolError
                },
                verificationAttempt: {
                    attempts.recordVerificationAttempt()
                }
            )
            XCTFail("Expected the protocol failure to leave immediately.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, protocolError)
        }

        XCTAssertEqual(attempts.initialAttempts, 1)
        XCTAssertEqual(attempts.verificationAttempts, 0)
    }
}

/// Device-side ports reserved by the in-memory trust fixture.
private enum TrustTestPort {
    /// Port on which the fixture exposes Remote Service Discovery.
    static let discovery: UInt16 = 54_130

    /// Port advertised for the untrusted remote-pairing service.
    static let pairingService: UInt16 = 63_795
}

/// Creates an isolated host identity for one trust-establishment test.
private func makeTrustIdentity() -> RemotePairingIdentity {
    RemotePairingIdentity(
        identifier: "test-host",
        privateKey: Curve25519.Signing.PrivateKey(),
        identityResolvingKey: Data(repeating: 0x7a, count: 16)
    )
}

/// Serializes progress callbacks because they may arrive from different tasks.
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

/// Counts enrollment and verification operations without data races.
private final class TrustAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInitialAttempts = 0
    private var recordedVerificationAttempts = 0

    var initialAttempts: Int {
        lock.withLock { recordedInitialAttempts }
    }

    var verificationAttempts: Int {
        lock.withLock { recordedVerificationAttempts }
    }

    func recordInitialAttempt() {
        lock.withLock {
            recordedInitialAttempts += 1
        }
    }

    @discardableResult
    func recordVerificationAttempt() -> Int {
        lock.withLock {
            recordedVerificationAttempts += 1
            return recordedVerificationAttempts
        }
    }
}

/// Records injected verification delays without introducing wall-clock waits.
private actor TrustAttemptDelayRecorder {
    /// Delays requested by the bounded post-enrollment attempt loop.
    private var recordedValues: [Duration] = []

    /// Snapshot of every requested delay in call order.
    var values: [Duration] {
        recordedValues
    }

    /// Records one delay instead of sleeping during a test.
    func record(_ duration: Duration) {
        recordedValues.append(duration)
    }
}

/// Routes requested device ports to deterministic in-memory connections.
private final class PortRoutingDeviceTransport: DeviceTransport {
    /// Ordered connections supplied for each device-side port.
    ///
    /// Repeated entries model reconnecting to the same RSD and pairing ports
    /// after the device terminates an enrollment stream.
    private var connectionSequences: [UInt16: [DeviceConnection]]

    /// Ports requested by the API in call order.
    private(set) var requestedPorts: [UInt16] = []

    /// Creates a transport with one connection for every expected service port.
    init(connections: [UInt16: DeviceConnection]) {
        connectionSequences = connections.mapValues { [$0] }
    }

    /// Creates a transport that can reconnect to selected service ports.
    init(connectionSequences: [UInt16: [DeviceConnection]]) {
        self.connectionSequences = connectionSequences
    }

    /// Returns and consumes the connection assigned to `port`.
    func connect(to port: UInt16) async throws -> DeviceConnection {
        requestedPorts.append(port)
        guard var connections = connectionSequences[port],
              !connections.isEmpty else {
            throw RorkDeviceError.invalidInput(
                "Unexpected test port \(port)."
            )
        }
        let connection = connections.removeFirst()
        connectionSequences[port] = connections
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

/// Builds the control-channel handshake response shared by trust exchanges.
private func trustHandshakeResponse() -> RemoteXPCValue {
    .dictionary([
        "response": .dictionary([
            "_1": .dictionary([
                "handshake": .dictionary([
                    "_0": .dictionary([:]),
                ]),
            ]),
        ]),
    ])
}

/// Builds an initial verification exchange that resets before manual setup.
private func trustPreEnrollmentResetWire() throws -> Data {
    var wire = try trustRemoteXPCWire([
        trustHandshakeResponse(),
    ])
    var resetPayload = Data()
    resetPayload.appendBigEndian(UInt32(0x08))
    wire.append(
        remoteXPCTestFrame(
            type: 0x03,
            streamIdentifier: 1,
            payload: resetPayload
        )
    )
    return wire
}

/// Builds one pair-verification exchange with a caller-selected final TLV.
private func trustVerificationWire(
    deviceAgreementKey: Curve25519.KeyAgreement.PrivateKey,
    finalFields: [TLV8Field]
) throws -> Data {
    try trustRemoteXPCWire([
        trustHandshakeResponse(),
        trustRemoteXPCPairingEvent(TLV8.encode([
            TLV8Field(type: 0x06, value: Data([0x02])),
            TLV8Field(
                type: 0x03,
                value: deviceAgreementKey.publicKey.rawRepresentation
            ),
        ])),
        trustRemoteXPCPairingEvent(TLV8.encode(finalFields)),
    ])
}
