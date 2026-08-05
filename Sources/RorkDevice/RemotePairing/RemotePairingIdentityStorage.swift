import Foundation

/// Persists remote-pairing identities with platform-appropriate file security.
protocol RemotePairingIdentityStorage: Sendable {
    /// Returns whether an identity file exists at `url`.
    func fileExists(at url: URL) -> Bool

    /// Reads an identity property list from `url`.
    func read(from url: URL) throws -> Data

    /// Atomically replaces the identity file at `url`.
    func write(_ data: Data, to url: URL) throws

    /// Creates an identity file without replacing a concurrent writer.
    ///
    /// - Returns: `true` when this call created the file.
    func createIfAbsent(_ data: Data, at url: URL) throws -> Bool
}

/// Creates the identity storage implementation for the current host platform.
func makeRemotePairingIdentityStorage() -> any RemotePairingIdentityStorage {
    #if os(Windows)
    WindowsRemotePairingIdentityStorage()
    #else
    POSIXRemotePairingIdentityStorage()
    #endif
}

/// Creates a unique sibling URL for one atomic identity-file operation.
func identitySiblingURL(
    for url: URL,
    suffix: String
) -> URL {
    url
        .deletingLastPathComponent()
        .appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).\(suffix)"
        )
}
