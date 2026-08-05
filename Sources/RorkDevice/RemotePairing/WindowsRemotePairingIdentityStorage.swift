#if os(Windows)
import Foundation
import RorkDevicePlatform

/// Stores identities atomically with an owner-only Windows access-control list.
struct WindowsRemotePairingIdentityStorage:
    RemotePairingIdentityStorage
{
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        _ = try writeAtomically(data, to: url, replaceExisting: true)
    }

    func createIfAbsent(_ data: Data, at url: URL) throws -> Bool {
        try writeAtomically(
            data,
            to: url,
            replaceExisting: false
        )
    }

    /// Writes through a protected sibling and publishes it with one native move.
    private func writeAtomically(
        _ data: Data,
        to url: URL,
        replaceExisting: Bool
    ) throws -> Bool {
        let temporaryURL = identitySiblingURL(
            for: url,
            suffix: replaceExisting ? "tmp" : "candidate"
        )
        let destinationPath = Array(url.path.utf16) + [0]
        let temporaryPath = Array(temporaryURL.path.utf16) + [0]
        var errorCode: UInt32 = 0
        let result = data.withUnsafeBytes { bytes in
            destinationPath.withUnsafeBufferPointer { destination in
                temporaryPath.withUnsafeBufferPointer { temporary in
                    rork_windows_write_file_atomically(
                        destination.baseAddress,
                        temporary.baseAddress,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count,
                        replaceExisting ? 1 : 0,
                        &errorCode
                    )
                }
            }
        }

        switch result {
        case 0:
            return true
        case 1 where !replaceExisting:
            return false
        default:
            throw windowsIdentityFileError(
                code: errorCode,
                url: url
            )
        }
    }
}

/// Returns whether the identity file grants access only to the current user.
func windowsIdentityFileHasCurrentUserOnlyAccess(
    at url: URL
) throws -> Bool {
    let path = Array(url.path.utf16) + [0]
    var hasProtectedAccess: Int32 = 0
    var errorCode: UInt32 = 0
    let result = path.withUnsafeBufferPointer { path in
        rork_windows_file_has_current_user_only_access(
            path.baseAddress,
            &hasProtectedAccess,
            &errorCode
        )
    }
    guard result == 0 else {
        throw windowsIdentityFileError(code: errorCode, url: url)
    }
    return hasProtectedAccess != 0
}

private func windowsIdentityFileError(
    code: UInt32,
    url: URL
) -> NSError {
    NSError(
        domain: "NSWin32ErrorDomain",
        code: Int(code),
        userInfo: [
            "NSFilePath": url.path
        ]
    )
}
#endif
