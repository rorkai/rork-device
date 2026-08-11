import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import ZipArchive

/// This source identifies a remote personalized DDI Restore archive.
public struct DeveloperDiskImageSource: Equatable, Sendable {
    /// This HTTPS location contains the ZIP archive.
    public let archiveURL: URL

    /// This lowercase SHA-256 authenticates the downloaded archive.
    public let expectedSHA256: String

    /// Creates an authenticated archive source.
    ///
    /// The library intentionally does not select or endorse a hosting provider.
    /// Applications must choose their source and pin the exact archive digest.
    ///
    /// - Parameters:
    ///   - archiveURL: This HTTPS URL identifies the ZIP archive.
    ///   - expectedSHA256: This hexadecimal SHA-256 is normalized to lowercase.
    /// - Throws: The initializer throws `RorkDeviceError.invalidInput` when the
    ///   URL is not HTTPS or the digest is not 64 hexadecimal characters.
    public init(
        archiveURL: URL,
        expectedSHA256: String
    ) throws(RorkDeviceError) {
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

/// This value contains HTTP metadata returned after an archive download.
struct DeveloperDiskImageArchiveHTTPResponse: Sendable {
    /// The archive host returned this final HTTP status.
    let statusCode: Int

    /// The server declared this length, or omitted it when the value is nil.
    let expectedContentLength: Int64?
}

/// This protocol keeps archive storage tests independent of the network.
protocol DeveloperDiskImageArchiveDownloading: Sendable {
    /// Downloads an archive while enforcing the caller's byte budget.
    ///
    /// - Parameters:
    ///   - sourceURL: The caller selected this authenticated HTTPS source.
    ///   - destinationURL: The caller owns this downloaded archive path.
    ///   - maximumByteCount: The response must not exceed this byte count.
    /// - Returns: The response includes metadata for download validation.
    /// - Throws: The method throws an input, transport, or filesystem failure.
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumByteCount: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse
}

/// These limits bound extraction of an untrusted archive.
struct DeveloperDiskImageArchiveLimits: Sendable {
    /// Production uses these archive size, entry count, and expansion limits.
    static let standard = DeveloperDiskImageArchiveLimits(
        maximumArchiveSize: 512 * 1024 * 1024,
        maximumEntryCount: 10_000,
        maximumExpandedSize: 2 * 1024 * 1024 * 1024
    )

    /// The compressed archive must not exceed this size.
    let maximumArchiveSize: UInt64

    /// The archive must not exceed this number of ZIP entries.
    let maximumEntryCount: Int

    /// The archive must not exceed this total uncompressed size.
    let maximumExpandedSize: UInt64
}

/// Downloads, authenticates, and caches personalized DDI archives.
public struct DeveloperDiskImageStore: Sendable {
    /// Initialization standardizes this root so equivalent paths share keys.
    private let cacheDirectory: URL

    /// This Sendable boundary keeps platform networking replaceable in tests.
    private let downloader: any DeveloperDiskImageArchiveDownloading

    /// The same limits govern download validation and archive extraction.
    private let limits: DeveloperDiskImageArchiveLimits

    /// Command-line and host applications use this default cache.
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
    /// - Parameter cacheDirectory: This directory stores digest-keyed images.
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
    /// reused without contacting the archive host again. Final publication is
    /// serialized per cache entry across processes, so concurrent stores cannot
    /// replace a directory another caller just published.
    ///
    /// The returned directory remains owned by the shared cache. Callers may
    /// read its contents but must not mutate or remove them.
    ///
    /// - Parameter source: This source provides the archive location and digest.
    /// - Returns: The local directory contains `BuildManifest.plist`.
    /// - Throws: The method throws an input error for invalid archive content,
    ///   a filesystem error for failed cache access, or a transport error when
    ///   the download fails. It throws `RorkDeviceError.cancelled` when the
    ///   caller cancels preparation.
    public func prepareRestoreDirectory(
        from source: DeveloperDiskImageSource
    ) async throws(RorkDeviceError) -> URL {
        return try await withRorkDeviceError {
            try await performRestoreDirectoryPreparation(
                from: source
            )
        }
    }

    /// Performs download and extraction before serialized final publication.
    ///
    /// - Parameter source: This source contains the archive location and digest.
    /// - Returns: The local directory contains `BuildManifest.plist`.
    /// - Throws: The operation throws cancellation or an input, filesystem, or
    ///   transport failure.
    private func performRestoreDirectoryPreparation(
        from source: DeveloperDiskImageSource
    ) async throws -> URL {
        try Task.checkCancellation()
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
            throw RorkDeviceError.fileSystem(
                path: cacheDirectory.path,
                reason: error.localizedDescription
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
            throw RorkDeviceError.fileSystem(
                path: operationDirectory.path,
                reason: error.localizedDescription
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
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw RorkDeviceError.transport(
                "Developer Disk Image archive download failed: \(error.localizedDescription)"
            )
        }
        try Task.checkCancellation()
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
        try Task.checkCancellation()

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
            throw RorkDeviceError.fileSystem(
                path: extractedDirectory.path,
                reason: error.localizedDescription
            )
        }
        try extractArchive(
            at: archiveURL,
            to: extractedDirectory,
            limits: limits
        )
        try Task.checkCancellation()

        let extractedRestoreDirectory = try restoreDirectory(
            in: extractedDirectory
        )
        let preparedDirectory = operationDirectory.appendingPathComponent(
            "prepared",
            isDirectory: true
        )
        let preparedRestoreDirectory = preparedDirectory.appendingPathComponent(
            "Restore",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: preparedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            if isCompleteRestoreDirectory(finalRestoreDirectory) {
                return finalRestoreDirectory
            }
            throw RorkDeviceError.fileSystem(
                path: preparedDirectory.path,
                reason: error.localizedDescription
            )
        }
        do {
            try FileManager.default.moveItem(
                at: extractedRestoreDirectory,
                to: preparedRestoreDirectory
            )
        } catch {
            if isCompleteRestoreDirectory(finalRestoreDirectory) {
                return finalRestoreDirectory
            }
            throw RorkDeviceError.fileSystem(
                path: preparedRestoreDirectory.path,
                reason: error.localizedDescription
            )
        }
        try Task.checkCancellation()
        return try await publishPreparedDirectory(
            preparedDirectory,
            to: finalDirectory,
            restoreDirectory: finalRestoreDirectory
        )
    }

    /// Publishes one prepared directory while this process owns its cache entry.
    ///
    /// - Parameters:
    ///   - preparedDirectory: This complete directory is ready for publication.
    ///   - finalDirectory: The digest-keyed cache entry is published here.
    ///   - restoreDirectory: This path identifies the final Restore directory.
    /// - Returns: The result is the complete cache-owned Restore directory.
    /// - Throws: The method throws cancellation or a filesystem failure.
    private func publishPreparedDirectory(
        _ preparedDirectory: URL,
        to finalDirectory: URL,
        restoreDirectory: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let lockURL = finalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(finalDirectory.lastPathComponent).publication.lock"
            )
        let publicationLock = try DeveloperDiskImagePublicationFileLock(
            fileURL: lockURL
        )
        return try await publicationLock.withLock {
            try Task.checkCancellation()
            return try replaceCacheEntry(
                at: finalDirectory,
                restoreDirectory: restoreDirectory,
                with: preparedDirectory
            )
        }
    }

    /// Rechecks and replaces one cache entry while publication is serialized.
    ///
    /// An incomplete entry is renamed into the caller's operation directory
    /// before publication. The outer cleanup removes it after the lock is
    /// released, which keeps this critical section limited to atomic renames.
    ///
    /// - Parameters:
    ///   - finalDirectory: This digest-keyed directory receives the cache entry.
    ///   - restoreDirectory: This path identifies the final Restore directory.
    ///   - preparedDirectory: This complete directory is ready for publication.
    /// - Returns: The result is the complete cache-owned Restore directory.
    /// - Throws: The method throws a filesystem failure when publication fails.
    private func replaceCacheEntry(
        at finalDirectory: URL,
        restoreDirectory: URL,
        with preparedDirectory: URL
    ) throws -> URL {
        if isCompleteRestoreDirectory(restoreDirectory) {
            return restoreDirectory
        }
        let discardedDirectory = preparedDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                "discarded-cache",
                isDirectory: true
            )
        if FileManager.default.fileExists(atPath: finalDirectory.path) {

            // Another process can publish between the first check and this branch.
            if isCompleteRestoreDirectory(restoreDirectory) {
                return restoreDirectory
            }
            do {
                try FileManager.default.moveItem(
                    at: finalDirectory,
                    to: discardedDirectory
                )
            } catch {
                if isCompleteRestoreDirectory(restoreDirectory) {
                    return restoreDirectory
                }
                throw RorkDeviceError.fileSystem(
                    path: finalDirectory.path,
                    reason: error.localizedDescription
                )
            }
        }
        do {
            try FileManager.default.moveItem(
                at: preparedDirectory,
                to: finalDirectory
            )
        } catch {
            if isCompleteRestoreDirectory(restoreDirectory) {
                return restoreDirectory
            }
            if !FileManager.default.fileExists(
                atPath: finalDirectory.path
            ) {
                try? FileManager.default.moveItem(
                    at: discardedDirectory,
                    to: finalDirectory
                )
            }
            throw RorkDeviceError.fileSystem(
                path: finalDirectory.path,
                reason: error.localizedDescription
            )
        }
        return restoreDirectory
    }
}

/// Holds an operating-system lock for one digest publication file.
///
/// The lock file remains in the cache, but its advisory lock is released when
/// the handle closes or the process exits. This makes publication crash-safe
/// across independent processes without stale lock cleanup.
///
/// The unchecked conformance is safe because the handle is immutable and all
/// shared exclusion state remains inside the operating system.
final class DeveloperDiskImagePublicationFileLock: @unchecked Sendable {
    /// Failures identify this lock file in their filesystem context.
    private let fileURL: URL

    #if os(Windows)
    /// Windows owns the lock through this kernel file handle.
    private let handle: HANDLE
    #elseif canImport(Darwin) || canImport(Glibc)
    /// POSIX owns the lock through this open file descriptor.
    private let fileDescriptor: CInt
    #else
    /// Unsupported hosts serialize publication within this process.
    private static let fallbackLock = NSLock()
    #endif

    /// Opens or creates the persistent lock file without acquiring it.
    ///
    /// - Parameter fileURL: This hidden file represents one digest cache entry.
    /// - Throws: The initializer throws `RorkDeviceError.fileSystem` when the
    ///   operating system cannot open the lock file.
    init(fileURL: URL) throws(RorkDeviceError) {
        self.fileURL = fileURL
        #if os(Windows)
        let handle = fileURL.path.withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_DELETE)
                    | DWORD(FILE_SHARE_READ)
                    | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw RorkDeviceError.fileSystem(
                path: fileURL.path,
                reason: "Windows could not open the publication lock. Error \(GetLastError())."
            )
        }
        self.handle = handle
        #elseif canImport(Darwin)
        let fileDescriptor: CInt = fileURL.withUnsafeFileSystemRepresentation {
            guard let path = $0 else {
                return CInt(-1)
            }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else {
            throw RorkDeviceError.fileSystem(
                path: fileURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        self.fileDescriptor = fileDescriptor
        #elseif canImport(Glibc)
        let fileDescriptor: CInt = fileURL.withUnsafeFileSystemRepresentation {
            guard let path = $0 else {
                return CInt(-1)
            }
            return Glibc.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else {
            throw RorkDeviceError.fileSystem(
                path: fileURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        self.fileDescriptor = fileDescriptor
        #endif
    }

    /// Closes the operating-system handle and releases any remaining lock.
    deinit {
        #if os(Windows)
        _ = CloseHandle(handle)
        #elseif canImport(Darwin)
        _ = Darwin.close(fileDescriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(fileDescriptor)
        #endif
    }

    /// Runs one publication while holding the exclusive file lock.
    ///
    /// - Parameter operation: This publication must remain indivisible.
    /// - Returns: The operation produces this value.
    /// - Throws: The method throws lock acquisition or operation failure.
    func withLock<Result>(
        _ operation: @Sendable () throws -> Result
    ) async throws -> Result {
        try await lock()
        defer {
            unlock()
        }
        return try operation()
    }

    /// Acquires an exclusive lock that the operating system releases on exit.
    private func lock() async throws {
        #if os(Windows)
        while true {
            try Task.checkCancellation()
            var overlapped = OVERLAPPED()
            if LockFileEx(
                handle,
                DWORD(LOCKFILE_EXCLUSIVE_LOCK)
                    | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
                0,
                UInt32.max,
                UInt32.max,
                &overlapped
            ) {
                return
            }
            let errorCode = GetLastError()
            guard errorCode == ERROR_LOCK_VIOLATION else {
                throw RorkDeviceError.fileSystem(
                    path: fileURL.path,
                    reason: "Windows could not acquire the publication lock. Error \(errorCode)."
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #elseif canImport(Darwin)
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            try Task.checkCancellation()
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            if lockErrno != EINTR {
                throw RorkDeviceError.fileSystem(
                    path: fileURL.path,
                    reason: String(cString: strerror(lockErrno))
                )
            }
        }
        #elseif canImport(Glibc)
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            try Task.checkCancellation()
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            if lockErrno != EINTR {
                throw RorkDeviceError.fileSystem(
                    path: fileURL.path,
                    reason: String(cString: strerror(lockErrno))
                )
            }
        }
        #else
        while !Self.fallbackLock.try() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #endif
    }

    /// Releases the exclusive lock after publication reaches a terminal result.
    private func unlock() {
        #if os(Windows)
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(
            handle,
            0,
            UInt32.max,
            UInt32.max,
            &overlapped
        )
        #elseif canImport(Darwin)
        _ = flock(fileDescriptor, LOCK_UN)
        #elseif canImport(Glibc)
        _ = flock(fileDescriptor, LOCK_UN)
        #else
        Self.fallbackLock.unlock()
        #endif
    }
}

/// This URLSession downloader preserves default certificate validation.
#if canImport(FoundationNetworking) || canImport(Darwin)
private struct URLSessionDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    /// Downloads one archive to a caller-owned temporary destination.
    ///
    /// - Parameters:
    ///   - sourceURL: The caller selected this HTTPS source.
    ///   - destinationURL: The caller owns this completed archive path.
    ///   - maximumByteCount: The response must not exceed this byte count.
    /// - Returns: The result includes the HTTP status and declared length.
    /// - Throws: The method throws an input, transport, or filesystem failure.
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
        do {
            try FileManager.default.copyItem(
                at: temporaryURL,
                to: destinationURL
            )
        } catch {
            throw RorkDeviceError.fileSystem(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }
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
    /// Reports that authenticated downloads are unavailable on this platform.
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
///
/// - Parameter fileURL: This local file is hashed without loading it into memory.
/// - Returns: The result is a lowercase hexadecimal SHA-256.
/// - Throws: The function throws `RorkDeviceError.fileSystem` when the file
///   cannot be read, or `CancellationError` when the caller cancels hashing.
func sha256HexDigest(of fileURL: URL) throws -> String {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: fileURL)
    } catch {
        throw RorkDeviceError.fileSystem(
            path: fileURL.path,
            reason: error.localizedDescription
        )
    }
    defer {
        try? handle.close()
    }
    var hasher = SHA256()
    while true {
        try Task.checkCancellation()
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        } catch {
            throw RorkDeviceError.fileSystem(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map {
        String(format: "%02x", $0)
    }.joined()
}

/// Returns the nonzero size of a regular, non-symbolic-link archive.
///
/// - Parameter fileURL: This local archive is inspected without following a link.
/// - Returns: The result is the positive archive size in bytes.
/// - Throws: The function throws `RorkDeviceError.fileSystem` when metadata
///   cannot be read, or `RorkDeviceError.invalidInput` for an unusable archive.
private func fileSize(at fileURL: URL) throws -> UInt64 {
    let values: URLResourceValues
    do {
        values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
    } catch {
        throw RorkDeviceError.fileSystem(
            path: fileURL.path,
            reason: error.localizedDescription
        )
    }
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
///
/// - Parameters:
///   - archiveURL: This ZIP archive has already passed digest verification.
///   - extractedDirectory: The caller owns this empty extraction directory.
///   - limits: These limits bound entry count and expanded size.
/// - Throws: The function throws `RorkDeviceError.invalidInput` when extraction
///   violates policy.
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
///
/// - Parameters:
///   - error: This archive-reader failure needs classification.
///   - limits: The diagnostic includes values from these limits.
/// - Returns: The result is a stable high-level input error.
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
///
/// - Parameter extractedDirectory: This is the authenticated extraction root.
/// - Returns: The result is a direct or singly nested `Restore` directory.
/// - Throws: The function throws `RorkDeviceError.invalidInput` for bad layout.
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
///
/// - Parameter directory: This candidate may contain a complete Restore image.
/// - Returns: The result reports whether a regular build manifest is present.
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
