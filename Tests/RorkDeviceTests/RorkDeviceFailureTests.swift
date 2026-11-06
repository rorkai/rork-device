import Foundation
import NIOCore
import XCTest

@testable import RorkDevice

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Pins the machine-readable failure contract supervisors branch on.
final class RorkDeviceFailureTests: XCTestCase {
    /// Each failure class a supervisor already distinguishes maps from the
    /// typed error, and the message keeps the text older supervisors match.
    func testSupervisorFailureClassesMapFromTypedErrors() {
        let cases: [(any Error, RorkDeviceFailure.Code, String)] = [
            (
                RorkDeviceError.deviceNotFound(identifier: "PHONE-1", usbOnly: false),
                .deviceNotFound,
                "No matching device found."
            ),
            (
                RorkDeviceError.deviceNotFound(identifier: nil, usbOnly: true),
                .deviceNotFound,
                "No matching USB device found."
            ),
            (
                LockdownPairingError.deviceLocked,
                .deviceLocked,
                "Unlock the device before pairing."
            ),
            (
                RorkDeviceError.deviceLocked(request: "StartService"),
                .deviceLocked,
                "Lockdown error: StartService failed: PasswordProtected"
            ),
            (
                RorkDeviceError.connectionClosed,
                .connectionClosed,
                "Transport error: Connection closed."
            ),
            (
                RorkDeviceError.localConnectionClosed,
                .connectionClosed,
                "Transport error: Connection is closed."
            ),
            (
                RorkDeviceError.connectionReset("Connection reset by peer."),
                .connectionClosed,
                "Transport error: Connection reset by peer."
            ),
            (
                RorkDeviceError.remoteXPCStreamReset(streamIdentifier: 1, errorCode: 5),
                .streamReset,
                "RemoteXPC reset HTTP/2 stream 1 with error code 5."
            ),
            (
                RorkDeviceError.timedOut("TLS connection timed out."),
                .timeout,
                "TLS connection timed out."
            ),
            (
                RorkDeviceError.remotePairing(.unknownPeer),
                .trustNotRecognized,
                "The device does not recognize this remote-pairing identity."
            ),
            (
                RorkDeviceError.remotePairingApprovalIncomplete,
                .pairingApprovalIncomplete,
                "Protocol violation: Remote pairing response is missing pairing data."
            ),
        ]

        for (error, code, message) in cases {
            let failure = RorkDeviceFailure(error)
            XCTAssertEqual(failure.code, code, "\(error)")
            XCTAssertEqual(failure.message, message, "\(error)")
        }
    }

    func testRemotePairingRejectionsKeepTheirDistinctions() {
        XCTAssertEqual(
            RorkDeviceFailure(RorkDeviceError.remotePairing(.backoff(retryDelay: .milliseconds(1_500)))),
            RorkDeviceFailure(
                code: .remotePairingBackoff,
                message: "Remote pairing is temporarily unavailable; retry after 1.5 seconds.",
                details: .init(retryAfterMilliseconds: 1_500)
            )
        )
        XCTAssertEqual(
            RorkDeviceFailure(RorkDeviceError.remotePairing(.unrecognized(code: 42))).details,
            .init(rejectionCode: 42)
        )
        XCTAssertEqual(
            RorkDeviceFailure(RorkDeviceError.remotePairing(.maximumPeers)).code,
            .remotePairingCapacityReached
        )
    }

    /// A device-supplied backoff too large for milliseconds saturates
    /// instead of trapping while the failure is reported.
    func testAnUnrepresentableBackoffSaturates() {
        let failure = RorkDeviceFailure(
            RorkDeviceError.remotePairing(.backoff(retryDelay: .seconds(Int64.max)))
        )

        XCTAssertEqual(failure.details?.retryAfterMilliseconds, .max)
    }

    func testTrustDialogOutcomesMapToDistinctCodes() {
        XCTAssertEqual(RorkDeviceFailure(LockdownPairingError.userConfirmationRequired).code, .awaitingTrust)
        XCTAssertEqual(RorkDeviceFailure(LockdownPairingError.userDenied).code, .trustDenied)
        XCTAssertEqual(RorkDeviceFailure(LockdownPairingError.timedOut).code, .trustTimeout)
        XCTAssertEqual(RorkDeviceFailure(LockdownPairingError.prohibited).code, .pairingProhibited)
        XCTAssertEqual(
            RorkDeviceFailure(LockdownPairingError.rejected("SomethingNew")),
            RorkDeviceFailure(
                code: .pairingRejected,
                message: "Lockdown rejected pairing: SomethingNew",
                details: .init(deviceErrorCode: "SomethingNew")
            )
        )
    }

    /// A request that outlives the tunnel's absence reports why the tunnel
    /// was lost as its cause, instead of folding it into the message only.
    func testTunnelUnavailableCarriesTheLossAsItsCause() {
        let loss = RorkDeviceError.deviceLocked(request: "StartService").failure

        let failure = RorkDeviceFailure(
            RorkDeviceError.tunnelUnavailable(lastFailure: loss)
        )

        XCTAssertEqual(failure.code, .tunnelUnavailable)
        XCTAssertEqual(failure.cause, loss)
        XCTAssertEqual(
            failure.message,
            "Transport error: The tunnel is not ready (last failure: Lockdown error: StartService failed: PasswordProtected) and no session became available in time."
        )
    }

    /// The check-in wrapper adds context without hiding a closed connection,
    /// which supervisors retry on.
    func testTransportStepKeepsTheUnderlyingClassification() {
        let failure = RorkDeviceFailure(
            RorkDeviceError.transportStep(
                context: "Remote service com.apple.example on [fd00::1]:5000 closed while waiting for StartService",
                underlying: RorkDeviceError.connectionClosed.failure
            )
        )

        XCTAssertEqual(failure.code, .connectionClosed)
        XCTAssertEqual(failure.cause?.code, .connectionClosed)
        XCTAssertEqual(
            failure.message,
            "Transport error: Remote service com.apple.example on [fd00::1]:5000 closed while waiting for StartService: Transport error: Connection closed."
        )
    }

    /// A step that inherits its cause's code also carries the cause's
    /// details, so a code always comes with the details it implies.
    func testTransportStepCarriesTheUnderlyingDetails() {
        let failure = RorkDeviceFailure(
            RorkDeviceError.transportStep(
                context: "Remote service com.apple.example on [fd00::1]:5000 closed while waiting for StartService",
                underlying: RorkDeviceError.remoteXPCStreamReset(
                    streamIdentifier: 3,
                    errorCode: 5
                ).failure
            )
        )

        XCTAssertEqual(failure.code, .streamReset)
        XCTAssertEqual(failure.details?.http2ErrorCode, 5)
    }

    func testTransportStepFallsBackToTransportForForeignErrors() {
        struct Foreign: Error {}

        let failure = RorkDeviceFailure(
            RorkDeviceError.transportStep(
                context: "Remote service com.apple.example on 127.0.0.1:5000 closed while waiting for RSDCheckin",
                underlying: RorkDeviceFailure(Foreign())
            )
        )

        XCTAssertEqual(failure.code, .transport)
        XCTAssertEqual(failure.cause?.code, .unknown)
    }

    func testForeignErrorsAreUnknownAndCancellationIsTyped() {
        struct Foreign: Error, CustomStringConvertible {
            var description: String { "something odd" }
        }

        XCTAssertEqual(
            RorkDeviceFailure(Foreign()),
            RorkDeviceFailure(code: .unknown, message: "something odd")
        )
        XCTAssertEqual(RorkDeviceFailure(CancellationError()).code, .cancelled)
    }

    /// The encoded shape is the wire contract: code and message always,
    /// details and cause only when present.
    func testEncodesTheWireShape() throws {
        let failure = RorkDeviceFailure(
            RorkDeviceError.tunnelUnavailable(
                lastFailure: RorkDeviceError.remoteXPCStreamReset(
                    streamIdentifier: 7,
                    errorCode: 5
                ).failure
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let json = String(decoding: try encoder.encode(failure), as: UTF8.self)

        XCTAssertEqual(
            json,
            #"{"cause":{"code":"stream-reset","details":{"http2ErrorCode":5,"streamIdentifier":7},"message":"RemoteXPC reset HTTP/2 stream 7 with error code 5."},"code":"tunnel-unavailable","message":"Transport error: The tunnel is not ready (last failure: RemoteXPC reset HTTP/2 stream 7 with error code 5.) and no session became available in time."}"#
        )
    }

    /// Consumers built against this release keep decoding failures that
    /// carry codes added later.
    func testDecodesRoundTripAndTreatsNewCodesAsUnknown() throws {
        let failure = RorkDeviceFailure(
            RorkDeviceError.tunnelUnavailable(
                lastFailure: RorkDeviceError.remoteXPCStreamReset(
                    streamIdentifier: 7,
                    errorCode: 5
                ).failure
            )
        )
        let decoded = try JSONDecoder().decode(
            RorkDeviceFailure.self,
            from: JSONEncoder().encode(failure)
        )
        XCTAssertEqual(decoded, failure)

        let future = try JSONDecoder().decode(
            RorkDeviceFailure.self,
            from: Data(#"{"code":"added-later","message":"m"}"#.utf8)
        )
        XCTAssertEqual(future.code, .unknown)
        XCTAssertEqual(future.message, "m")
    }

    func testEmptyDetailsAreOmitted() {
        XCTAssertNil(
            RorkDeviceFailure(code: .transport, message: "x", details: .init()).details
        )
    }

    func testCodesAreUniqueKebabCaseStrings() {
        let rawValues = RorkDeviceFailure.Code.allCases.map(\.rawValue)

        XCTAssertEqual(Set(rawValues).count, rawValues.count)
        for rawValue in rawValues {
            XCTAssertNotNil(
                rawValue.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression),
                rawValue
            )
        }
    }

    /// Socket resets and OS timeouts are recognized by error code, on every
    /// host's error domain, rather than by their localized text.
    func testRecognizesResetAndTimeoutSocketErrors() {
        #if os(Windows)
        XCTAssertTrue(isConnectionResetError(IOError(winsock: WSAECONNRESET, reason: "read")))
        XCTAssertTrue(isTimedOutError(IOError(winsock: WSAETIMEDOUT, reason: "connect")))
        XCTAssertFalse(isConnectionResetError(IOError(winsock: WSAETIMEDOUT, reason: "read")))
        #else
        XCTAssertTrue(isConnectionResetError(IOError(errnoCode: ECONNRESET, reason: "read")))
        XCTAssertTrue(isTimedOutError(IOError(errnoCode: ETIMEDOUT, reason: "connect")))
        XCTAssertFalse(isConnectionResetError(IOError(errnoCode: ETIMEDOUT, reason: "read")))
        #endif
    }
}
