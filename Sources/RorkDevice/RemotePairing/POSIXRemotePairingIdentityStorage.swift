#if !os(Windows)
import Foundation

struct POSIXRemotePairingIdentityStorage:
    RemotePairingIdentityStorage,
    @unchecked Sendable
{
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

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
