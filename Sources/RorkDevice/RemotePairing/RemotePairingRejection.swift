import Foundation

/// A device-reported reason for rejecting a remote-pairing request.
///
/// These values come from the pairing protocol's error TLV. Callers can use
/// them to distinguish an identity that may enter manual pair setup from
/// rate limits and capacity failures that must be surfaced without retrying.
public enum RemotePairingRejection:
    Equatable,
    Sendable,
    CustomStringConvertible
{
    /// The device rejected the request without a more specific reason.
    case unknown

    /// Signature verification or setup-code authentication failed.
    case authentication

    /// The device requires the client to wait before another pairing attempt.
    case backoff(retryDelay: Duration?)

    /// The device does not recognize the presented host identity.
    case unknownPeer

    /// The device cannot store another paired identity.
    case maximumPeers

    /// The device has accepted the maximum number of authentication attempts.
    case maximumAttempts

    /// A newer or otherwise unsupported error code returned by the device.
    case unrecognized(code: UInt8)

    /// Human-readable context suitable for CLI output and diagnostics.
    public var description: String {
        switch self {
        case .unknown:
            return "Remote pairing failed for an unspecified reason."
        case .authentication:
            return "Remote pairing authentication failed."
        case let .backoff(retryDelay):
            if let retryDelay {
                return "Remote pairing is temporarily unavailable; retry after \(retryDelay)."
            }
            return "Remote pairing is temporarily unavailable; retry later."
        case .unknownPeer:
            return "The device does not recognize this remote-pairing identity."
        case .maximumPeers:
            return "The device cannot accept another remote-pairing identity."
        case .maximumAttempts:
            return "The device rejected remote pairing after too many authentication attempts."
        case let .unrecognized(code):
            return "The device rejected remote pairing with unrecognized error code \(code)."
        }
    }

    /// Whether this rejection permits starting manual pair setup.
    var allowsPairSetup: Bool {
        switch self {
        case .authentication, .unknownPeer:
            return true
        case .unknown, .backoff, .maximumPeers, .maximumAttempts, .unrecognized:
            return false
        }
    }
}
