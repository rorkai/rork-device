import Foundation
import XCTest

@testable import RorkDevice

final class DeveloperDiskImageSessionTests: XCTestCase {
    func testMountUsesMobileImageMounterForSupportedDevice() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "ImageSignature": [Data([0x01])],
                "Status": "Complete",
            ])
        )
        let backend = DeveloperDiskImageSessionTestBackend(
            deviceInfo: DeviceInfo(values: [
                "ProductVersion": "18.5",
                "UniqueChipID": "303775031541788",
            ]),
            developerModeEnabled: true,
            connections: [connection]
        )
        let session = DeviceSession(backend: backend)

        let result = try await session
            .mountPersonalizedDeveloperDiskImage(
                from: fixture.restoreDirectory
            )

        XCTAssertEqual(result.status, .alreadyMounted)
        XCTAssertEqual(
            backend.startedServiceNames,
            ["com.apple.mobile.mobile_image_mounter"]
        )
        XCTAssertTrue(connection.isClosed)
    }

    func testMountRejectsPreIOS17Device() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let backend = DeveloperDiskImageSessionTestBackend(
            deviceInfo: DeviceInfo(values: [
                "ProductVersion": "16.7.12",
                "UniqueChipID": "123",
            ]),
            developerModeEnabled: true,
            connections: []
        )
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync({
            try await session.mountPersonalizedDeveloperDiskImage(
                from: fixture.restoreDirectory
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Personalized Developer Disk Images require iOS 17 or newer."
                )
            )
        }
        XCTAssertTrue(backend.startedServiceNames.isEmpty)
    }

    func testAutomaticMountChecksDeviceBeforeDownloading() async throws {
        let downloader = UnexpectedDeveloperDiskImageArchiveDownloader()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let store = DeveloperDiskImageStore(
            cacheDirectory: cacheDirectory,
            downloader: downloader
        )
        let source = try DeveloperDiskImageSource(
            archiveURL: URL(string: "https://example.com/ddi.zip")!,
            expectedSHA256: String(repeating: "a", count: 64)
        )
        let backend = DeveloperDiskImageSessionTestBackend(
            deviceInfo: DeviceInfo(values: [
                "ProductVersion": "16.7.12",
                "UniqueChipID": "123",
            ]),
            developerModeEnabled: true,
            connections: []
        )
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync({
            try await session.mountPersonalizedDeveloperDiskImage(
                from: source,
                using: store
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Personalized Developer Disk Images require iOS 17 or newer."
                )
            )
        }
        XCTAssertEqual(downloader.downloadCount, 0)
    }

    func testMountRequiresDeveloperMode() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let backend = DeveloperDiskImageSessionTestBackend(
            deviceInfo: DeviceInfo(values: [
                "ProductVersion": "18.5",
                "UniqueChipID": "123",
            ]),
            developerModeEnabled: false,
            connections: []
        )
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync({
            try await session.mountPersonalizedDeveloperDiskImage(
                from: fixture.restoreDirectory
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .invalidInput(
                    "Developer Mode must be enabled before mounting a personalized Developer Disk Image."
                )
            )
        }
        XCTAssertTrue(backend.startedServiceNames.isEmpty)
    }

    func testMountRequiresECID() async throws {
        let fixture = try makeImageFixture(
            boardID: "0x0C",
            chipID: "0x8150",
            securityDomain: "0x01"
        )
        defer { fixture.remove() }
        let backend = DeveloperDiskImageSessionTestBackend(
            deviceInfo: DeviceInfo(values: [
                "ProductVersion": "18.5",
            ]),
            developerModeEnabled: true,
            connections: []
        )
        let session = DeviceSession(backend: backend)

        await XCTAssertThrowsErrorAsync({
            try await session.mountPersonalizedDeveloperDiskImage(
                from: fixture.restoreDirectory
            )
        }) { error in
            XCTAssertEqual(
                error as? RorkDeviceError,
                .protocolViolation(
                    "Lockdown did not report a valid UniqueChipID for Developer Disk Image personalization."
                )
            )
        }
        XCTAssertTrue(backend.startedServiceNames.isEmpty)
    }
}

private final class UnexpectedDeveloperDiskImageArchiveDownloader:
    DeveloperDiskImageArchiveDownloading
{
    private(set) var downloadCount = 0

    func download(
        from _: URL,
        to _: URL,
        maximumByteCount _: UInt64
    ) async throws -> DeveloperDiskImageArchiveHTTPResponse {
        downloadCount += 1
        throw RorkDeviceError.transport(
            "Archive download should not have started."
        )
    }
}

private final class DeveloperDiskImageSessionTestBackend:
    DeviceSessionBackend
{
    private let deviceInfo: DeviceInfo
    private let developerModeEnabled: Bool
    private var connections: [DeviceConnection]
    private(set) var startedServiceNames: [String] = []

    init(
        deviceInfo: DeviceInfo,
        developerModeEnabled: Bool,
        connections: [DeviceConnection]
    ) {
        self.deviceInfo = deviceInfo
        self.developerModeEnabled = developerModeEnabled
        self.connections = connections
    }

    func fetchDeviceInfo() async throws -> DeviceInfo {
        deviceInfo
    }

    func isDeveloperModeEnabled() async throws -> Bool {
        developerModeEnabled
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedServiceNames.append(serviceName)
        guard !connections.isEmpty else {
            throw RorkDeviceError.transport(
                "No image-mounter test connection remains."
            )
        }
        return connections.removeFirst()
    }
}
