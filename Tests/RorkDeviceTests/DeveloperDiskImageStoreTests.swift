import Crypto
import Foundation
import XCTest
import ZIPFoundation

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
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(
            at: fixture.restoreDirectory.appendingPathComponent("image-link"),
            withDestinationURL: fixture.restoreDirectory.appendingPathComponent(
                "DeveloperDiskImage.dmg"
            )
        )
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
    try FileManager.default.zipItem(
        at: restoreDirectory,
        to: archiveURL,
        shouldKeepParent: true,
        compressionMethod: .deflate
    )
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
    let archive = try Archive(url: archiveURL, accessMode: .create)
    for entry in entries {
        try archive.addEntry(
            with: entry.path,
            type: .file,
            uncompressedSize: Int64(entry.data.count)
        ) { position, size in
            let lowerBound = Int(position)
            let upperBound = min(
                lowerBound + size,
                entry.data.count
            )
            return entry.data.subdata(
                in: lowerBound ..< upperBound
            )
        }
    }
    return DeveloperDiskImageArchiveFixture(
        directory: directory,
        url: archiveURL
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
}
