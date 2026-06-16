import Foundation
import NIOCore

/// Parses an IPv6 literal into its 16-byte network representation.
///
/// Centralizing this conversion keeps gateway clients and userspace network
/// backends consistent while preserving a caller-specific diagnostic.
func ipv6AddressBytes(
    _ address: String,
    invalidMessage: String
) throws -> Data {
    let address = address.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let socketAddress: SocketAddress
    do {
        socketAddress = try SocketAddress(
            ipAddress: address,
            port: 0
        )
    } catch {
        throw RorkDeviceError.invalidInput(invalidMessage)
    }

    guard case .v6(let ipv6Address) = socketAddress else {
        throw RorkDeviceError.invalidInput(invalidMessage)
    }
    var bytes = ipv6Address.address.sin6_addr
    return withUnsafeBytes(of: &bytes) { Data($0) }
}
