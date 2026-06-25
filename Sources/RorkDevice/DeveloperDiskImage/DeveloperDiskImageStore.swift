import Crypto
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import ZipArchive

/// Remote archive containing an iOS 17+ personalized DDI Restore directory.
public struct DeveloperDiskImageSource: Equatable, Sendable {
    /// HTTPS location of the ZIP archive.
    public let archiveURL: URL

    /// Lowercase SHA-256 used to authenticate the downloaded archive.
    public let expectedSHA256: String

    /// Creates an authenticated archive source.
    ///
    /// The library intentionally does not select or endorse a hosting provider.
    /// Applications must choose their source and pin the exact archive digest.
    ///
    /// - Parameters:
    ///   - archiveURL: HTTPS URL for the ZIP archive.
    ///   - expectedSHA256: Expected archive SHA-256 in hexadecimal form. The
    ///     stored value is normalized to lowercase.
    /// - Throws: `RorkDeviceError.invalidInput` when the URL is not HTTPS or
    ///   the digest is not exactly 64 hexadecimal characters.
    public init(archiveURL: URL, expectedSHA256: String) throws {
        guard archiveURL.scheme?.lowercased() == "https",
            archiveURL.host != nil
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image archive URL must use HTTPS."
            )
        }
        let normalizedDigest = expectedSHA256.lowercased()
        let hexadecimalBytes = normalizedDigest.utf8
        guard hexadecimalBytes.count == SHA256.Digest.byteCount * 2,
            hexadecimalBytes.allSatisfy({
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a") ... UInt8(ascii: "f"))
                        .contains($0)
            })
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image archive SHA-256 must contain 64 hexadecimal characters."
            )
        }
        self.archiveURL = archiveURL
        self.expectedSHA256 = normalizedDigest
    }
}

/// HTTP metadata returned after an archive download.
struct DeveloperDiskImageArchiveHTTPResponse: Sendable {
    /// Final HTTP status returned by the archive host.
    let statusCode: Int

    /// Declared response length, or `nil` when the server omitted it.
    let expectedContentLength: Int64?
}

/// Download boundary used to keep archive storage tests offline.
protocol DeveloperDiskImageArchiveDownloading: Sendable {
    /// Downloads an archive while enforcing the caller's byte budget.
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumByteCount: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse
}

/// Resource bounds applied before extracting an untrusted archive.
struct DeveloperDiskImageArchiveLimits: Sendable {
    /// Production limits for archive size, entry count, and expansion.
    static let standard = DeveloperDiskImageArchiveLimits(
        maximumArchiveSize: 512 * 1024 * 1024,
        maximumEntryCount: 10_000,
        maximumExpandedSize: 2 * 1024 * 1024 * 1024
    )

    /// Maximum compressed archive size accepted on disk or over the network.
    let maximumArchiveSize: UInt64

    /// Maximum number of ZIP entries inspected before extraction.
    let maximumEntryCount: Int

    /// Maximum total uncompressed size across all ZIP entries.
    let maximumExpandedSize: UInt64
}

/// Downloads, authenticates, and caches personalized DDI archives.
public struct DeveloperDiskImageStore: Sendable {
    private let cacheDirectory: URL
    private let downloader: any DeveloperDiskImageArchiveDownloading
    private let limits: DeveloperDiskImageArchiveLimits

    /// Default cache used by the command-line client and host applications.
    public static let defaultCacheDirectory: URL = {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(
            "rork-device/DeveloperDiskImages",
            isDirectory: true
        )
    }()

    /// Creates a DDI archive store.
    ///
    /// - Parameter cacheDirectory: Directory for digest-keyed extracted images.
    public init(
        cacheDirectory: URL = DeveloperDiskImageStore.defaultCacheDirectory
    ) {
        let downloader: any DeveloperDiskImageArchiveDownloading
        #if canImport(FoundationNetworking) || canImport(Darwin)
        downloader = URLSessionDeveloperDiskImageArchiveDownloader()
        #else
        downloader = UnavailableDeveloperDiskImageArchiveDownloader()
        #endif
        self.init(
            cacheDirectory: cacheDirectory,
            downloader: downloader,
            limits: .standard
        )
    }

    /// Creates a store with injectable I/O and resource limits for tests.
    init(
        cacheDirectory: URL,
        downloader: any DeveloperDiskImageArchiveDownloading,
        limits: DeveloperDiskImageArchiveLimits = .standard
    ) {
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.downloader = downloader
        self.limits = limits
    }

    /// Returns a verified, extracted `Restore` directory for `source`.
    ///
    /// Downloads are keyed by the pinned SHA-256. A completed cache entry is
    /// reused without contacting the archive host again.
    ///
    /// - Parameter source: HTTPS archive location and expected digest.
    /// - Returns: Local directory containing `BuildManifest.plist`.
    /// - Throws: An input error when the archive, digest, ZIP layout, or cache
    ///   contents are invalid; a transport error when the download fails.
    public func prepareRestoreDirectory(
        from source: DeveloperDiskImageSource
    ) async throws -> URL {
        let finalDirectory = cacheDirectory.appendingPathComponent(
            source.expectedSHA256,
            isDirectory: true
        )
        let finalRestoreDirectory = finalDirectory.appendingPathComponent(
            "Restore",
            isDirectory: true
        )
        if isCompleteRestoreDirectory(finalRestoreDirectory) {
            return finalRestoreDirectory
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not create Developer Disk Image cache: \(error.localizedDescription)"
            )
        }

        let operationDirectory = cacheDirectory.appendingPathComponent(
            ".\(source.expectedSHA256)-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: operationDirectory)
        }
        do {
            try FileManager.default.createDirectory(
                at: operationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not prepare Developer Disk Image cache: \(error.localizedDescription)"
            )
        }

        let archiveURL = operationDirectory.appendingPathComponent(
            "archive.zip"
        )
        let response: DeveloperDiskImageArchiveHTTPResponse
        do {
            response = try await downloader.download(
                from: source.archiveURL,
                to: archiveURL,
                maximumByteCount: limits.maximumArchiveSize
            )
        } catch let error as RorkDeviceError {
            throw error
        } catch {
            throw RorkDeviceError.transport(
                "Developer Disk Image archive download failed: \(error.localizedDescription)"
            )
        }
        guard response.statusCode == 200 else {
            throw RorkDeviceError.transport(
                "Developer Disk Image archive returned HTTP status \(response.statusCode)."
            )
        }

        let archiveSize = try fileSize(at: archiveURL)
        guard archiveSize <= limits.maximumArchiveSize else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image archive exceeds the \(limits.maximumArchiveSize)-byte limit."
            )
        }
        if let expectedLength = response.expectedContentLength,
            expectedLength >= 0,
            UInt64(expectedLength) != archiveSize
        {
            throw RorkDeviceError.transport(
                "Developer Disk Image archive length did not match the HTTP response."
            )
        }
        guard try sha256HexDigest(of: archiveURL)
            == source.expectedSHA256
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image archive SHA-256 did not match the expected digest."
            )
        }

        let extractedDirectory = operationDirectory.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: extractedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not prepare Developer Disk Image extraction: \(error.localizedDescription)"
            )
        }
        try extractArchive(
            at: archiveURL,
            to: extractedDirectory,
            limits: limits
        )

        let extractedRestoreDirectory = try restoreDirectory(
            in: extractedDirectory
        )
        let preparedDirectory = operationDirectory.appendingPathComponent(
            "prepared",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: preparedDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: extractedRestoreDirectory,
                to: preparedDirectory.appendingPathComponent(
                    "Restore",
                    isDirectory: true
                )
            )
            if isCompleteRestoreDirectory(finalRestoreDirectory) {
                return finalRestoreDirectory
            }
            if FileManager.default.fileExists(atPath: finalDirectory.path) {
                try FileManager.default.removeItem(at: finalDirectory)
            }
            try FileManager.default.moveItem(
                at: preparedDirectory,
                to: finalDirectory
            )
        } catch {
            if isCompleteRestoreDirectory(finalRestoreDirectory) {
                return finalRestoreDirectory
            }
            throw RorkDeviceError.invalidInput(
                "Could not cache Developer Disk Image: \(error.localizedDescription)"
            )
        }
        return finalRestoreDirectory
    }
}

/// URLSession downloader that preserves default certificate validation.
#if canImport(FoundationNetworking) || canImport(Darwin)
private struct URLSessionDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    /// Downloads one archive to a caller-owned temporary destination.
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumByteCount: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        let delegate = DeveloperDiskImageDownloadDelegate(
            maximumByteCount: maximumByteCount
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(
                for: URLRequest(url: sourceURL)
            )
        } catch {
            if delegate.didExceedLimit {
                throw RorkDeviceError.invalidInput(
                    "Developer Disk Image archive exceeds the \(maximumByteCount)-byte limit."
                )
            }
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RorkDeviceError.transport(
                "Developer Disk Image archive host did not return an HTTP response."
            )
        }
        try FileManager.default.copyItem(
            at: temporaryURL,
            to: destinationURL
        )
        let expectedLength = httpResponse.expectedContentLength
        return DeveloperDiskImageArchiveHTTPResponse(
            statusCode: httpResponse.statusCode,
            expectedContentLength: expectedLength >= 0
                ? expectedLength
                : nil
        )
    }
}

/// Enforces archive size and HTTPS redirect policy during a download.
private final class DeveloperDiskImageDownloadDelegate:
    HTTPSOnlyURLSessionDelegate,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    /// Maximum number of compressed bytes accepted from the response body.
    private let maximumByteCount: UInt64

    /// Serializes byte-limit state across URLSession delegate callbacks.
    private let lock = NSLock()

    /// Records whether cancellation was caused by the configured byte limit.
    private var exceededLimit = false

    /// Creates a delegate with one compressed-response byte budget.
    init(maximumByteCount: UInt64) {
        self.maximumByteCount = maximumByteCount
    }

    /// Whether this delegate cancelled a download after exceeding its limit.
    var didExceedLimit: Bool {
        lock.withLock { exceededLimit }
    }

    /// Cancels a chunked response as soon as its compressed bytes exceed the
    /// configured archive limit.
    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        guard totalBytesWritten >= 0,
            UInt64(totalBytesWritten) > maximumByteCount
        else {
            return
        }
        lock.withLock {
            exceededLimit = true
        }
        downloadTask.cancel()
    }

    /// Leaves file ownership to URLSession's async download API.
    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo _: URL
    ) {}
}
#else
/// Reports that this platform has no authenticated HTTP client implementation.
private struct UnavailableDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    func download(
        from _: URL,
        to _: URL,
        maximumByteCount _: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        throw RorkDeviceError.transport(
            "Developer Disk Image archive downloads are unavailable on this platform."
        )
    }
}
#endif

/// Returns a lowercase streaming SHA-256 for a file.
func sha256HexDigest(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer {
        try? handle.close()
    }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024),
        !chunk.isEmpty
    {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map {
        String(format: "%02x", $0)
    }.joined()
}

/// Returns the nonzero size of a regular, non-symbolic-link archive.
private func fileSize(at fileURL: URL) throws -> UInt64 {
    let values = try fileURL.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        let size = values.fileSize,
        size > 0
    else {
        throw RorkDeviceError.invalidInput(
            "Developer Disk Image archive is missing or empty."
        )
    }
    return UInt64(size)
}

/// Extracts one authenticated archive using DDI-specific safety policies.
private func extractArchive(
    at archiveURL: URL,
    to extractedDirectory: URL,
    limits: DeveloperDiskImageArchiveLimits
) throws {
    let options = ZipArchiveExtractionOptions(
        symbolicLinkPolicy: .reject,
        limits: .init(
            maximumEntryCount: limits.maximumEntryCount,
            maximumTotalUncompressedSize: Int64(
                clamping: limits.maximumExpandedSize
            )
        )
    )
    do {
        try ZipArchiveReader.withFile(archiveURL.path) { reader in
            try reader.extract(
                to: .init(extractedDirectory.path),
                options: options
            )
        }
    } catch let error as ZipArchiveReaderError {
        throw developerDiskImageArchiveError(
            for: error,
            limits: limits
        )
    } catch {
        throw RorkDeviceError.invalidInput(
            "Could not extract Developer Disk Image archive: \(error.localizedDescription)"
        )
    }
}

/// Maps backend-specific safety failures to store-level diagnostics.
private func developerDiskImageArchiveError(
    for error: ZipArchiveReaderError,
    limits: DeveloperDiskImageArchiveLimits
) -> RorkDeviceError {
    if error == .entryCountLimitExceeded {
        return .invalidInput(
            "Developer Disk Image archive contains more than \(limits.maximumEntryCount) entries."
        )
    }
    if error == .totalUncompressedSizeLimitExceeded {
        return .invalidInput(
            "Developer Disk Image archive expands beyond the \(limits.maximumExpandedSize)-byte limit."
        )
    }
    if error == .symbolicLinkNotAllowed {
        return .invalidInput(
            "Developer Disk Image archive contains symbolic links."
        )
    }
    if error == .unsafeExtractionPath
        || error == .duplicateExtractionPath
        || error == .conflictingExtractionPath
        || error == .unsafeDestinationPath
    {
        return .invalidInput(
            "Developer Disk Image archive contains an unsafe or duplicate path."
        )
    }
    return .invalidInput(
        "Could not extract Developer Disk Image archive: \(error.localizedDescription)"
    )
}

/// Finds exactly one complete `Restore` directory in a common ZIP layout.
private func restoreDirectory(in extractedDirectory: URL) throws -> URL {
    let direct = extractedDirectory.appendingPathComponent(
        "Restore",
        isDirectory: true
    )
    if isCompleteRestoreDirectory(direct) {
        return direct
    }

    let children: [URL]
    do {
        children = try FileManager.default.contentsOfDirectory(
            at: extractedDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
    } catch {
        throw RorkDeviceError.invalidInput(
            "Could not inspect Developer Disk Image archive: \(error.localizedDescription)"
        )
    }
    let candidates = children.compactMap { child -> URL? in
        let values = try? child.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true,
            values?.isSymbolicLink != true
        else {
            return nil
        }
        let candidate = child.appendingPathComponent(
            "Restore",
            isDirectory: true
        )
        return isCompleteRestoreDirectory(candidate)
            ? candidate
            : nil
    }
    guard candidates.count == 1,
        let candidate = candidates.first
    else {
        throw RorkDeviceError.invalidInput(
            "Developer Disk Image archive must contain one Restore/BuildManifest.plist."
        )
    }
    return candidate
}

/// Checks the cache marker without following a symbolic-link manifest.
private func isCompleteRestoreDirectory(_ directory: URL) -> Bool {
    let manifestURL = directory.appendingPathComponent(
        "BuildManifest.plist"
    )
    guard let values = try? manifestURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ) else {
        return false
    }
    return values.isRegularFile == true
        && values.isSymbolicLink != true
}
