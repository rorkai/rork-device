import Foundation

protocol RemotePairingIdentityStorage: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func createIfAbsent(_ data: Data, at url: URL) throws -> Bool
}

func remotePairingIdentityStorage() -> any RemotePairingIdentityStorage {
    #if os(Windows)
    WindowsRemotePairingIdentityStorage()
    #else
    POSIXRemotePairingIdentityStorage()
    #endif
}

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
