#if !os(Windows)
import Foundation

/// Stores identities in owner-readable POSIX files using atomic sibling moves.
///
/// The value has no mutable state outside Foundation's thread-safe file
/// manager, which allows storage operations to cross task boundaries.
struct POSIXRemotePairingIdentityStorage:
    RemotePairingIdentityStorage,
    @unchecked Sendable
{
    /// Filesystem implementation used for persistence.
    let fileManager: FileManager

    /// Creates storage backed by `fileManager`.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Reports whether an identity already exists at the destination.
    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Loads the persisted identity bytes.
    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Replaces an identity through an owner-only sibling file.
    func write(_ data: Data, to url: URL) throws {
        let temporaryURL = identitySiblingURL(for: url, suffix: "tmp")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try writeNewFile(data, to: temporaryURL)
        if fileExists(at: url) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    /// Publishes a new identity without replacing an existing destination.
    ///
    /// The return value is `false` when the destination already exists.
    func createIfAbsent(_ data: Data, at url: URL) throws -> Bool {
        let candidateURL = identitySiblingURL(
            for: url,
            suffix: "candidate"
        )
        defer {
            try? fileManager.removeItem(at: candidateURL)
        }

        do {
            try writeNewFile(data, to: candidateURL)
            try fileManager.linkItem(at: candidateURL, to: url)
            return true
        } catch {
            guard fileExists(at: url) else {
                throw error
            }
            return false
        }
    }

    /// Creates and fills a new file whose POSIX mode grants owner access only.
    private func writeNewFile(
        _ data: Data,
        to url: URL
    ) throws {
        guard
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [
                    .posixPermissions: NSNumber(value: 0o600)
                ]
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
#endif
