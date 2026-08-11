import Crypto
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import ZipArchive

@testable import RorkDevice

/// Verifies authenticated archive preparation and cache safety.
final class DeveloperDiskImageStoreTests: XCTestCase {
    func testSourceRequiresHTTPSAndSHA256() throws {
        XCTAssertThrowsError(
            try DeveloperDiskImageSource(
                archiveURL: URL(string: "http://example.com/ddi.zip")!,
                expectedSHA256: String(repeating: "a", count: 64)
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive URL must use HTTPS."
                )
            )
        }

        XCTAssertThrowsError(
            try DeveloperDiskImageSource(
                archiveURL: URL(string: "https://example.com/ddi.zip")!,
                expectedSHA256: "not-a-digest"
            )
        ) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive SHA-256 must contain 64 hexadecimal characters."
                )
            )
        }
    }

    func testPrepareRestoreDirectoryDownloadsOnceAndReusesCache()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let archive = try makeArchive(containing: fixture.restoreDirectory)
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        let first = try await store.prepareRestoreDirectory(from: source)
        let second = try await store.prepareRestoreDirectory(from: source)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "Restore")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.appendingPathComponent(
                    "BuildManifest.plist"
                ).path
            )
        )
        XCTAssertEqual(downloader.downloadCount, 1)
    }

    /// Proves separate stores serialize publication after overlapping downloads.
    func testConcurrentPreparationSerializesDigestPublication() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let archive = try makeArchive(containing: fixture.restoreDirectory)
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = BarrierDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let firstStore = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )
        let secondStore = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        async let first = firstStore.prepareRestoreDirectory(from: source)
        async let second = secondStore.prepareRestoreDirectory(from: source)
        let preparedDirectories = try await [first, second]
        let downloadCount = await downloader.downloadCount

        XCTAssertEqual(preparedDirectories[0], preparedDirectories[1])
        XCTAssertEqual(downloadCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preparedDirectories[0]
                    .appendingPathComponent("BuildManifest.plist")
                    .path
            )
        )
    }

    /// Proves independent file handles honor the publication lock.
    func testPublicationFileLockSerializesIndependentHandles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent("publication.lock")
        let firstLock = try DeveloperDiskImagePublicationFileLock(
            fileURL: lockURL
        )
        let secondLock = try DeveloperDiskImagePublicationFileLock(
            fileURL: lockURL
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        let first = Task.detached {
            try await firstLock.withLock {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(
            firstEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        let second = Task.detached {
            secondAttempted.signal()
            try await secondLock.withLock {
                _ = secondEntered.signal()
            }
        }
        XCTAssertEqual(
            secondAttempted.wait(timeout: .now() + .seconds(1)),
            .success
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(secondEntered.wait(timeout: .now()), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        try await first.value
        try await second.value
    }

    /// Proves cancellation interrupts a pending publication lock wait.
    func testPublicationFileLockWaitIsCancellable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent("publication.lock")
        let firstLock = try DeveloperDiskImagePublicationFileLock(
            fileURL: lockURL
        )
        let secondLock = try DeveloperDiskImagePublicationFileLock(
            fileURL: lockURL
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let first = Task.detached {
            try await firstLock.withLock {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(
            firstEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        let second = Task.detached {
            secondAttempted.signal()
            return try await secondLock.withLock {
                true
            }
        }
        XCTAssertEqual(
            secondAttempted.wait(timeout: .now() + .seconds(1)),
            .success
        )
        try await Task.sleep(for: .milliseconds(20))
        let outcomeRecorder = PublicationLockOutcomeRecorder()
        let observation = Task {
            do {
                _ = try await second.value
                await outcomeRecorder.record(.acquired)
            } catch is CancellationError {
                await outcomeRecorder.record(.cancelled)
            } catch {
                await outcomeRecorder.record(
                    .failed(String(describing: error))
                )
            }
        }

        second.cancel()
        for _ in 0..<100 {
            if await outcomeRecorder.outcome != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let outcomeWhileLocked = await outcomeRecorder.outcome

        releaseFirst.signal()
        await observation.value
        try await first.value
        XCTAssertEqual(outcomeWhileLocked, .cancelled)
    }

    /// Proves cancellation remains typed while a download is suspended.
    func testPreparationPreservesCancellation() async throws {
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = CancellableDeveloperDiskImageArchiveDownloader()
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: String(repeating: "0", count: 64)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )
        let preparation = Task {
            try await store.prepareRestoreDirectory(from: source)
        }
        await downloader.waitUntilStarted()

        preparation.cancel()

        do {
            _ = try await preparation.value
            XCTFail("The cancelled preparation should not succeed.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, .cancelled)
        }
        let remainingItems = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingItems.isEmpty)
    }

    func testPrepareRestoreDirectoryRejectsHTTPFailure() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let archive = try makeArchive(containing: fixture.restoreDirectory)
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url,
            statusCode: 404
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        await XCTAssertThrowsErrorAsync({
            try await store.prepareRestoreDirectory(from: source)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .transport(
                    "Developer Disk Image archive returned HTTP status 404."
                )
            )
        }
    }

    func testPrepareRestoreDirectoryRejectsDigestMismatch() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let archive = try makeArchive(containing: fixture.restoreDirectory)
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: String(repeating: "0", count: 64)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        await XCTAssertThrowsErrorAsync({
            try await store.prepareRestoreDirectory(from: source)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive SHA-256 did not match the expected digest."
                )
            )
        }
    }

    func testPrepareRestoreDirectoryRejectsSymbolicLinks() async throws {
        let archive = try makeSymbolicLinkArchive(
            path: "Restore/image-link",
            target: "DeveloperDiskImage.dmg"
        )
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        await XCTAssertThrowsErrorAsync({
            try await store.prepareRestoreDirectory(from: source)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive contains symbolic links."
                )
            )
        }
    }

    func testPrepareRestoreDirectoryEnforcesExpandedSizeLimit()
        async throws
    {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let archive = try makeArchive(containing: fixture.restoreDirectory)
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader,
            limits: DeveloperDiskImageArchiveLimits(
                maximumArchiveSize: 1024 * 1024,
                maximumEntryCount: 100,
                maximumExpandedSize: 1
            )
        )

        await XCTAssertThrowsErrorAsync({
            try await store.prepareRestoreDirectory(from: source)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive expands beyond the 1-byte limit."
                )
            )
        }
    }

    func testPrepareRestoreDirectoryRejectsCanonicalDuplicatePaths()
        async throws
    {
        for alias in [
            "Restore/./BuildManifest.plist",
            "Restore//BuildManifest.plist",
        ] {
            let archive = try makeArchive(entries: [
                ("Restore/BuildManifest.plist", Data("first".utf8)),
                (alias, Data("second".utf8)),
            ])
            defer { archive.remove() }
            let cacheDirectory = temporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: cacheDirectory)
            }
            let downloader = RecordingDeveloperDiskImageArchiveDownloader(
                archiveURL: archive.url
            )
            let source = try DeveloperDiskImageSource(
                archiveURL: URL(string: "https://example.com/ddi.zip")!,
                expectedSHA256: try sha256HexDigest(of: archive.url)
            )
            let store = DeveloperDiskImageStore(
                cacheDirectory: cacheDirectory,
                downloader: downloader
            )

            await XCTAssertThrowsErrorAsync({
                try await store.prepareRestoreDirectory(from: source)
            }) { error in
                XCTAssertEqual(
                    error as? RorkDeviceError,
                    .invalidInput(
                        "Developer Disk Image archive contains an unsafe or duplicate path."
                    )
                )
            }
        }
    }

    func testPrepareRestoreDirectoryRejectsFileDirectoryPathConflicts()
        async throws
    {
        let archive = try makeArchive(entries: [
            ("Restore", Data("file".utf8)),
            (
                "Restore/BuildManifest.plist",
                Data("manifest".utf8)
            ),
        ])
        defer { archive.remove() }
        let cacheDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let downloader = RecordingDeveloperDiskImageArchiveDownloader(
            archiveURL: archive.url
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: try sha256HexDigest(of: archive.url)
        )
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )

        await XCTAssertThrowsErrorAsync({
            try await store.prepareRestoreDirectory(from: source)
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Disk Image archive contains an unsafe or duplicate path."
                )
            )
        }
    }

    func testHTTPSRedirectPolicyRequiresHTTPS() {
        let secureRequest = URLRequest(
            url: URL(string: "https://cdn.example.com/ddi.zip")!
        )
        let insecureRequest = URLRequest(
            url: URL(string: "http://cdn.example.com/ddi.zip")!
        )

        XCTAssertNotNil(
            HTTPSOnlyURLSessionDelegate
                .approvedRedirectRequest(secureRequest)
        )
        XCTAssertNil(
            HTTPSOnlyURLSessionDelegate
                .approvedRedirectRequest(insecureRequest)
        )
    }
}

/// Copies one fixture archive and records sequential download requests.
private final class RecordingDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading,
    @unchecked Sendable
{
    /// This archive is copied into each caller-owned operation directory.
    private let archiveURL: URL

    /// This status is returned after the fixture copy.
    private let statusCode: Int

    /// This count records downloads started by the sequential test double.
    private(set) var downloadCount = 0

    /// Creates a downloader backed by one local archive and HTTP status.
    init(archiveURL: URL, statusCode: Int = 200) {
        self.archiveURL = archiveURL
        self.statusCode = statusCode
    }

    /// Copies the fixture and returns metadata matching its local byte count.
    func download(
        from _: URL,
        to destinationURL: URL,
        maximumByteCount _: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        downloadCount += 1
        try FileManager.default.copyItem(
            at: archiveURL,
            to: destinationURL
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: archiveURL.path
        )
        return DeveloperDiskImageArchiveHTTPResponse(
            statusCode: statusCode,
            expectedContentLength: (attributes[.size] as? NSNumber)?
                .int64Value
        )
    }
}

/// Holds the first download until a second store reaches the same phase.
private actor BarrierDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    /// This archive is copied into each caller-owned operation directory.
    private let archiveURL: URL

    /// This count records download operations started by the stores.
    private(set) var downloadCount = 0

    /// The first download remains suspended until the second request starts.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a barrier downloader backed by one local archive fixture.
    init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    /// Copies the fixture after both concurrent requests reach the barrier.
    func download(
        from _: URL,
        to destinationURL: URL,
        maximumByteCount _: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        downloadCount += 1
        if downloadCount < 2 {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
        try Task.checkCancellation()
        try FileManager.default.copyItem(
            at: archiveURL,
            to: destinationURL
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: archiveURL.path
        )
        return DeveloperDiskImageArchiveHTTPResponse(
            statusCode: 200,
            expectedContentLength: (attributes[.size] as? NSNumber)?
                .int64Value
        )
    }
}

/// Suspends one download until task cancellation proves error normalization.
private actor CancellableDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    /// This value records whether the download reached its suspension point.
    private var started = false

    /// These continuations let tests cancel only after the download has started.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until the store enters `download(from:to:maximumByteCount:)`.
    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    /// Suspends until cancellation interrupts the synthetic download.
    func download(
        from _: URL,
        to _: URL,
        maximumByteCount _: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
        try await Task.sleep(for: .seconds(60))
        throw RorkDeviceError.transport(
            "The cancellation test download unexpectedly resumed."
        )
    }
}

/// This outcome records how a contended publication lock wait ended.
private enum PublicationLockOutcome: Equatable, Sendable {
    /// The waiter entered the protected operation.
    case acquired

    /// Cancellation interrupted the waiter before lock acquisition.
    case cancelled

    /// An unexpected failure ended the waiter.
    case failed(String)
}

/// This recorder exposes a task outcome without awaiting the task indefinitely.
private actor PublicationLockOutcomeRecorder {
    /// The first terminal waiter outcome is retained for the assertion.
    private(set) var outcome: PublicationLockOutcome?

    /// Records one terminal waiter outcome.
    func record(_ outcome: PublicationLockOutcome) {
        self.outcome = outcome
    }
}

/// Owns a temporary archive and the directory removed during cleanup.
private struct DeveloperDiskImageArchiveFixture {
    /// This temporary directory contains the generated archive.
    let directory: URL

    /// This URL identifies the generated ZIP archive.
    let url: URL

    /// Removes the complete fixture tree.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Archives one complete Restore directory for successful preparation tests.
private func makeArchive(
    containing restoreDirectory: URL
) throws -> DeveloperDiskImageArchiveFixture {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let archiveURL = directory.appendingPathComponent("ddi.zip")
    let writer = ZipArchiveWriter()
    try writer.writeFolderContents(
        .init(restoreDirectory.path),
        options: [.recursive, .includeContainingFolder]
    )
    try Data(writer.finalizeBuffer()).write(to: archiveURL)
    return DeveloperDiskImageArchiveFixture(
        directory: directory,
        url: archiveURL
    )
}

/// Builds an archive from exact path and byte entries.
private func makeArchive(
    entries: [(path: String, data: Data)]
) throws -> DeveloperDiskImageArchiveFixture {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let archiveURL = directory.appendingPathComponent("ddi.zip")
    let writer = ZipArchiveWriter()
    var pathReplacements: [(safe: String, requested: String)] = []
    let requestedPaths = entries.map { $0.path }
    for entry in entries {
        let safePath = safeArchiveFixturePath(
            for: entry.path,
            among: requestedPaths
        )
        try writer.writeFile(
            filename: safePath,
            contents: Array(entry.data)
        )
        if safePath != entry.path {
            pathReplacements.append((safePath, entry.path))
        }
    }
    var archiveData = Data(try writer.finalizeBuffer())
    for replacement in pathReplacements {
        try replaceArchiveFixturePath(
            replacement.safe,
            with: replacement.requested,
            in: &archiveData
        )
    }
    try archiveData.write(to: archiveURL)
    return DeveloperDiskImageArchiveFixture(
        directory: directory,
        url: archiveURL
    )
}

/// Builds an archive containing one symbolic-link entry.
private func makeSymbolicLinkArchive(
    path: String,
    target: String
) throws -> DeveloperDiskImageArchiveFixture {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let archiveURL = directory.appendingPathComponent("ddi.zip")
    let writer = ZipArchiveWriter()
    try writer.writeFile(
        filename: path,
        contents: Array(target.utf8),
        metadata: .init(
            externalAttributes: .unix([
                .isSymbolicLink,
                .permissions([.ownerReadWrite]),
            ])
        )
    )
    try Data(writer.finalizeBuffer()).write(to: archiveURL)
    return DeveloperDiskImageArchiveFixture(
        directory: directory,
        url: archiveURL
    )
}

/// Produces a valid placeholder with the same byte count as a malformed path.
private func safeArchiveFixturePath(
    for requestedPath: String,
    among requestedPaths: [String]
) -> String {
    if requestedPath.contains("/./") {
        return requestedPath.replacingOccurrences(of: "/./", with: "/x/")
    }
    if requestedPath.contains("//") {
        return requestedPath.replacingOccurrences(of: "//", with: "/x")
    }
    if requestedPaths.contains(where: {
        $0.hasPrefix("\(requestedPath)/")
    }) {
        return "\(requestedPath.dropLast())_"
    }
    return requestedPath
}

/// Mutates both ZIP filename records because the writer rejects unsafe paths.
private func replaceArchiveFixturePath(
    _ safePath: String,
    with requestedPath: String,
    in archiveData: inout Data
) throws {
    let safeBytes = Data(safePath.utf8)
    let requestedBytes = Data(requestedPath.utf8)
    guard safeBytes.count == requestedBytes.count else {
        throw CocoaError(.fileWriteInvalidFileName)
    }

    var replacementCount = 0
    var searchStart = archiveData.startIndex
    while searchStart < archiveData.endIndex,
        let range = archiveData.range(
            of: safeBytes,
            in: searchStart ..< archiveData.endIndex
        )
    {
        archiveData.replaceSubrange(range, with: requestedBytes)
        replacementCount += 1
        searchStart = range.upperBound
    }
    guard replacementCount >= 2 else {
        throw CocoaError(.fileReadCorruptFile)
    }
}

/// Returns a unique path whose parent already exists.
private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
}
