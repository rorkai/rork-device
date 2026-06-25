import Crypto
import Foundation
import XCTest
import ZipArchive

@testable import RorkDevice

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

private final class RecordingDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading,
    @unchecked Sendable
{
    private let archiveURL: URL
    private let statusCode: Int
    private(set) var downloadCount = 0

    init(archiveURL: URL, statusCode: Int = 200) {
        self.archiveURL = archiveURL
        self.statusCode = statusCode
    }

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

private struct DeveloperDiskImageArchiveFixture {
    let directory: URL
    let url: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

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

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
}
