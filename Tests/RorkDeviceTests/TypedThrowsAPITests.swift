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

private struct TypedThrowsFailingTransport: DeviceTransport {
    let error: any Error

    func connect(to _: UInt16) async throws -> DeviceConnection {
        throw error
    }
}

private struct TypedThrowsBlockingTransport: DeviceTransport {
    func connect(to _: UInt16) async throws -> DeviceConnection {
        TypedThrowsBlockingConnection()
    }
}

private final class TypedThrowsBlockingConnection: DeviceConnection {
    func send(_: Data) async throws {}

    func receive(exactly _: Int) async throws -> Data {
        try await Task.sleep(for: .seconds(60))
        return Data()
    }

    func close() {}
}

private enum TypedThrowsTestError: Error, LocalizedError {
    case transport

    var errorDescription: String? {
        "Deliberate transport failure."
    }
}

private final class TypedThrowsTestBackend: DeviceSessionBackend {
    private let deviceInfoError: RorkDeviceError?

    init(deviceInfoError: RorkDeviceError? = nil) {
        self.deviceInfoError = deviceInfoError
    }

    func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        if let deviceInfoError {
            throw deviceInfoError
        }
        return DeviceInfo(values: [:])
    }

    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws(RorkDeviceError) -> DeviceConnection {
        throw RorkDeviceError.protocolViolation(
            "Unexpected service request \(serviceName)."
        )
    }
}

private final class TypedThrowsConnectionBackend: DeviceSessionBackend {
    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func fetchDeviceInfo() async throws(RorkDeviceError) -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    func startService(
        named _: String,
        escrowBag _: Data?
    ) async throws(RorkDeviceError) -> DeviceConnection {
        connection
    }
}
