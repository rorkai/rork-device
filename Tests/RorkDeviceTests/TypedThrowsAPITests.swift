import Foundation
import XCTest
@testable import RorkDevice

/// Compile-time and behavioral contracts for the high-level typed error surface.
final class TypedThrowsAPITests: XCTestCase {
    func testDeviceClientSignaturesThrowOnlyRorkDeviceError() async {
        let client = DeviceClient()

        #if canImport(NIOPosix) && !os(WASI)
        await requireRorkDeviceError(
            try await client.discoverDevices()
        )
        await requireRorkDeviceError(
            try await client.discoverDevice(identifier: "device")
        )
        await requireRorkDeviceError(
            try await client.pairingRecord(for: "device")
        )
        await requireRorkDeviceError(
            try await client.pair(
                with: unavailableValue(),
                trustTimeout: .seconds(1),
                retryInterval: .seconds(1)
            )
        )
        await requireRorkDeviceError(
            try await client.unpair(from: unavailableValue())
        )
        await requireRorkDeviceError(
            try await client.connect(
                to: unavailableValue(),
                using: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.deviceEnvironment(for: unavailableValue())
        )
        await requireRorkDeviceError(
            try await client.connect(
                to: "localhost",
                using: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.connect(
                toRemoteServicesAt: "localhost",
                port: 1
            )
        )
        #endif

        await requireRorkDeviceError(
            try await client.connect(
                over: unavailableValue(),
                using: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.pairingInformation(
                over: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.deviceEnvironment(
                over: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.pair(
                using: unavailableValue(),
                over: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.unpair(
                using: unavailableValue(),
                over: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await client.connect(
                toRemoteServicesUsing: unavailableValue(),
                discoveryPort: 1
            )
        )
    }

    func testDeviceSessionSignaturesThrowOnlyRorkDeviceError() async {
        let session = DeviceSession(
            backend: TypedThrowsTestBackend()
        )

        await requireRorkDeviceError(
            try await session.fetchDeviceInfo()
        )
        await requireRorkDeviceError(
            try await session.companionValue(
                for: CompanionRegistryKey<String>("DeviceName"),
                on: "device"
            )
        )
        await requireRorkDeviceError(
            try await session.companionValue(
                String.self,
                forKey: "DeviceName",
                on: "device"
            )
        )
        await requireRorkDeviceError(
            try await session.pairedCompanionDevices()
        )
        await requireRorkDeviceError(
            try await session.isDeveloperModeEnabled()
        )
        await requireRorkDeviceError(
            try await session.enableWirelessConnections()
        )
        await requireRorkDeviceError(
            try await session.revealDeveloperMode()
        )
        await requireRorkDeviceError(
            try await session.mountPersonalizedDeveloperDiskImage(
                from: URL(fileURLWithPath: "/tmp/Restore")
            )
        )
        await requireRorkDeviceError(
            try await session.mountPersonalizedDeveloperDiskImage(
                from: unavailableValue(),
                using: unavailableValue()
            )
        )
        await requireRorkDeviceError(
            try await session.unmountPersonalizedDeveloperDiskImage()
        )
        await requireRorkDeviceError(
            try await session.mountedPersonalizedDeveloperDiskImages()
        )
        await requireRorkDeviceError(
            try await session.startService(.afc)
        )
        await requireRorkDeviceError(
            try await session.startService(named: "com.apple.afc")
        )
        await requireRorkDeviceError(
            try await session.openCoreDeviceTunnel()
        )
        await requireRorkDeviceError(
            try await session.installProvisioningProfile(
                contentsOf: URL(fileURLWithPath: "/tmp/profile")
            )
        )
        await requireRorkDeviceError(
            try await session.installProvisioningProfile(Data())
        )
        await requireRorkDeviceError(
            try await session.removeProvisioningProfile(
                identifier: "profile"
            )
        )
        await requireRorkDeviceError(
            try await session.copyProvisioningProfiles()
        )
        await requireRorkDeviceError(
            try await session.startHeartbeat()
        )
        await requireRorkDeviceError(
            try await session.installedApplications()
        )
        await requireRorkDeviceError(
            try await session.rawApplications()
        )
        await requireRorkDeviceError(
            try await session.launchApplication(
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.terminateApplication(
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.uninstallApplication(
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.installApplication(
                at: URL(fileURLWithPath: "/tmp/app.ipa"),
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.installApplication(
                Data(),
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.stageApplication(
                at: URL(fileURLWithPath: "/tmp/app.ipa"),
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.stageApplication(
                Data(),
                bundleIdentifier: "com.example.app"
            )
        )
        await requireRorkDeviceError(
            try await session.openAFC()
        )
        await requireRorkDeviceError(
            try await session.openApplicationContainer(
                bundleIdentifier: "com.example.app"
            )
        )
    }

    /// Type-checks the authenticated source and cache preparation boundaries.
    func testDeveloperDiskImageStoreSignatureThrowsOnlyRorkDeviceError() async {
        let store = DeveloperDiskImageStore()

        await requireRorkDeviceError(
            try DeveloperDiskImageSource(
                archiveURL: unavailableValue(),
                expectedSHA256: ""
            )
        )
        await requireRorkDeviceError(
            try await store.prepareRestoreDirectory(
                from: unavailableValue()
            )
        )
    }

    func testDeviceClientNormalizesCancellation() async {
        let client = DeviceClient()

        do {
            _ = try await client.pairingInformation(
                over: TypedThrowsFailingTransport(
                    error: CancellationError()
                )
            )
            XCTFail("Cancellation should fail the operation.")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testDeviceClientNormalizesUnknownTransportFailure() async {
        let client = DeviceClient()

        do {
            _ = try await client.pairingInformation(
                over: TypedThrowsFailingTransport(
                    error: TypedThrowsTestError.transport
                )
            )
            XCTFail("The transport should fail the operation.")
        } catch {
            XCTAssertEqual(
                error,
                .transport("Deliberate transport failure.")
            )
        }
    }

    func testDeviceEnvironmentPreservesCancellation() async {
        let client = DeviceClient()
        let operation = Task {
            try await client.deviceEnvironment(
                over: TypedThrowsBlockingTransport(),
                readTimeout: .seconds(60)
            )
        }

        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Cancellation should fail the environment read.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, .cancelled)
        }
    }

    func testDeviceEnvironmentReportsReadTimeout() async {
        let client = DeviceClient()

        do {
            _ = try await client.deviceEnvironment(
                over: TypedThrowsBlockingTransport(),
                readTimeout: .milliseconds(20)
            )
            XCTFail("The environment read should time out.")
        } catch let .transport(message) {
            XCTAssertTrue(
                message.contains("Lockdown did not answer device values within")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeviceSessionPreservesProtocolFailure() async {
        let expectedError = RorkDeviceError.protocolViolation(
            "Deliberate protocol failure."
        )
        let session = DeviceSession(
            backend: TypedThrowsTestBackend(
                deviceInfoError: expectedError
            )
        )

        do {
            _ = try await session.fetchDeviceInfo()
            XCTFail("The backend should fail the operation.")
        } catch {
            XCTAssertEqual(error, expectedError)
        }
    }

    func testRemoteServiceDiscoveryConnectionClosesWhenHandshakeFails()
        async
    {
        let connection = FakeConnection()
        let client = DeviceClient()

        do {
            _ = try await client.connect(
                toRemoteServicesUsing: TypedThrowsConnectionTransport(
                    connection: connection
                ),
                discoveryPort: 58_783
            )
            XCTFail("The empty discovery handshake should fail.")
        } catch {
            XCTAssertFalse(error.description.isEmpty)
        }
        XCTAssertTrue(connection.isClosed)
    }

    func testProvisioningProfileReadMapsToFileSystemFailure() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mobileprovision")
        let session = DeviceSession(
            backend: TypedThrowsTestBackend()
        )

        do {
            try await session.installProvisioningProfile(
                contentsOf: missingURL
            )
            XCTFail("Reading a missing profile should fail.")
        } catch let RorkDeviceError.fileSystem(path, reason) {
            XCTAssertEqual(path, missingURL.path)
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransientServiceClosesAfterSuccessfulOperation() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "CurrentAmount": 0,
                "CurrentIndex": 0,
                "CurrentList": [],
                "Status": "Complete",
            ])
        )
        let session = DeviceSession(
            backend: TypedThrowsConnectionBackend(
                connection: connection
            )
        )

        _ = try await session.installedApplications()

        XCTAssertTrue(connection.isClosed)
    }

    func testTransientServiceClosesAfterFailedOperation() async {
        let connection = FakeConnection(
            inbound: Data([0, 0, 0, 0])
        )
        let session = DeviceSession(
            backend: TypedThrowsConnectionBackend(
                connection: connection
            )
        )

        do {
            _ = try await session.installedApplications()
            XCTFail("The malformed service response should fail.")
        } catch {
            XCTAssertEqual(
                error,
                .protocolViolation(
                    "Property list message length was zero."
                )
            )
        }
        XCTAssertTrue(connection.isClosed)
    }

    func testHouseArrestConnectionClosesWhenVendingFails() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": "ApplicationLookupFailed",
                "ErrorDescription": "No such application",
            ])
        )
        let session = DeviceSession(
            backend: TypedThrowsConnectionBackend(
                connection: connection
            )
        )

        do {
            _ = try await session.openApplicationContainer(
                bundleIdentifier: "com.missing.app"
            )
            XCTFail("The container request should fail.")
        } catch {
            XCTAssertEqual(
                error,
                .protocolViolation(
                    "HouseArrest failed: ApplicationLookupFailed: No such application"
                )
            )
        }
        XCTAssertTrue(connection.isClosed)
    }

    func testHouseArrestConnectionStaysOpenAfterSuccessfulVend() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Status": "Complete",
            ])
        )
        let session = DeviceSession(
            backend: TypedThrowsConnectionBackend(
                connection: connection
            )
        )

        let client = try await session.openApplicationContainer(
            bundleIdentifier: "com.example.app"
        )

        XCTAssertFalse(connection.isClosed)
        client.close()
        XCTAssertTrue(connection.isClosed)
    }

    /// Proves an abandoned AFC client still releases its owned connection.
    func testAFCClientClosesConnectionDuringDeinitialization() {
        let connection = FakeConnection()
        var client: AFCClient? = AFCClient(connection: connection)

        XCTAssertNotNil(client)
        XCTAssertFalse(connection.isClosed)
        client = nil
        XCTAssertTrue(connection.isClosed)
    }
}

/// Type-checks an API expression without executing its operation.
private func requireRorkDeviceError<Result>(
    _ operation: @autoclosure () async throws(RorkDeviceError) -> Result
) async {
    _ = operation
}

/// Supplies unreachable values to compile-time-only API expressions.
private func unavailableValue<Value>() -> Value {
    fatalError("Compile-time signature checks never execute their closures.")
}

/// Injects one arbitrary implementation error at the transport boundary.
private struct TypedThrowsFailingTransport: DeviceTransport {
    /// This failure verifies high-level normalization.
    let error: any Error

    /// Throws the injected failure without opening a connection.
    func connect(to _: UInt16) async throws -> DeviceConnection {
        throw error
    }
}

/// Opens a connection whose reads remain pending until cancellation or close.
private struct TypedThrowsBlockingTransport: DeviceTransport {
    /// Creates an independently controllable blocking connection.
    func connect(to _: UInt16) async throws -> DeviceConnection {
        TypedThrowsBlockingConnection()
    }
}

/// Returns one observable connection for ownership tests.
private struct TypedThrowsConnectionTransport: DeviceTransport {
    /// The test inspects this connection's close state.
    let connection: DeviceConnection

    /// Returns the injected connection for every requested port.
    func connect(to _: UInt16) async throws -> DeviceConnection {
        connection
    }
}

/// Models a read that can be interrupted safely from cancellation or a watchdog.
private final class TypedThrowsBlockingConnection:
    DeviceConnection,
    @unchecked Sendable
{
    /// Protects the continuation and terminal state across tasks.
    private let lock = NSLock()

    /// This pending read resumes exactly once when the connection finishes.
    private var continuation: CheckedContinuation<Data, any Error>?

    /// Prevents a later read from suspending after closure.
    private var isClosed = false

    /// Accepts writes because these tests exercise only read interruption.
    func send(_: Data) async throws {}

    /// Suspends until cancellation or explicit closure supplies a failure.
    func receive(exactly _: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock {
                    if isClosed || Task.isCancelled {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            finish(with: CancellationError())
        }
    }

    /// Interrupts the pending read with a transport failure.
    func close() {
        finish(
            with: RorkDeviceError.transport("Connection is closed.")
        )
    }

    /// Records terminal state and resumes a pending read at most once.
    private func finish(with error: any Error) {
        let pending = lock.withLock {
            isClosed = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(throwing: error)
    }
}

/// Supplies a non-library failure with deterministic localized text.
private enum TypedThrowsTestError: Error, LocalizedError {
    /// This case represents a deliberate transport-layer implementation failure.
    case transport

    /// This text remains after normalization erases the implementation type.
    var errorDescription: String? {
        "Deliberate transport failure."
    }
}

/// This backend can fail device information without opening a service.
private final class TypedThrowsTestBackend: DeviceSessionBackend {
    /// This optional typed failure is returned by `fetchDeviceInfo()`.
    private let deviceInfoError: RorkDeviceError?

    /// Creates a backend with an optional device-information failure.
    init(deviceInfoError: RorkDeviceError? = nil) {
        self.deviceInfoError = deviceInfoError
    }

    /// Returns empty information or the injected typed failure.
    func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        if let deviceInfoError {
            throw deviceInfoError
        }
        return DeviceInfo(values: [:])
    }

    /// Rejects unexpected service access in compile-time and error tests.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws(RorkDeviceError) -> DeviceConnection {
        throw RorkDeviceError.protocolViolation(
            "Unexpected service request \(serviceName)."
        )
    }
}

/// This backend lends one observable connection to session operations.
private final class TypedThrowsConnectionBackend: DeviceSessionBackend {
    /// The test verifies this connection's ownership transitions.
    private let connection: DeviceConnection

    /// Creates a backend around one observable connection.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Returns the minimal device information required by these tests.
    func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Returns the injected connection for every service request.
    func startService(
        named _: String,
        escrowBag _: Data?
    ) async throws(RorkDeviceError) -> DeviceConnection {
        connection
    }
}
