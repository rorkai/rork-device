import Foundation
import XCTest
@testable import RorkDevice

final class DeviceSessionCoreDeviceTests: XCTestCase {
    func testTerminatesDeveloperApplicationByItsBundlePath() async throws {
        let applicationConnection = try coreDeviceAppServiceConnection(
            responses: [
                .array([
                    .dictionary([
                        "bundleIdentifier": .string(
                            "com.example.developer-app"
                        ),
                        "name": .string("Example Developer App"),
                        "path": .string(
                            "/private/var/containers/Bundle/Application/UUID/Example Developer App.app"
                        ),
                        "isDeveloperApp": .bool(true),
                        "isFirstParty": .bool(false),
                        "isInternal": .bool(false),
                    ]),
                ]),
            ]
        )
        let processConnection = try coreDeviceAppServiceConnection(responses: [
            .dictionary([
                "processTokens": .array([
                    .dictionary([
                        "processIdentifier": .int64(6_303),
                        "executableURL": .dictionary([
                            "relative": .string(
                                "file:///private/var/containers/Bundle/Application/UUID/Example%20Developer%20App.app/Example%20Developer%20App"
                            ),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let signalConnection = try coreDeviceAppServiceConnection(responses: [
            .dictionary([:]),
        ])
        let backend = CoreDeviceSessionTestBackend(
            remoteConnections: [
                applicationConnection,
                processConnection,
                signalConnection,
            ]
        )
        let session = DeviceSession(backend: backend)

        let terminated = try await session.terminateApplication(
            bundleIdentifier: "com.example.developer-app"
        )

        XCTAssertTrue(terminated)
        XCTAssertEqual(
            backend.startedRemoteServices,
            [
                CoreDeviceApplicationService.serviceName,
                CoreDeviceApplicationService.serviceName,
                CoreDeviceApplicationService.serviceName,
            ]
        )
        XCTAssertTrue(backend.startedLockdownServices.isEmpty)
    }

    func testReturnsFalseWhenDeveloperApplicationIsNotRunning() async throws {
        let applicationConnection = try coreDeviceAppServiceConnection(
            responses: [
                .array([
                    .dictionary([
                        "bundleIdentifier": .string(
                            "com.example.developer-app"
                        ),
                        "name": .string("Example Developer App"),
                        "path": .string(
                            "/private/var/containers/Bundle/Application/UUID/Example Developer App.app"
                        ),
                        "isDeveloperApp": .bool(true),
                        "isFirstParty": .bool(false),
                        "isInternal": .bool(false),
                    ]),
                ]),
            ]
        )
        let processConnection = try coreDeviceAppServiceConnection(responses: [
            .dictionary([
                "processTokens": .array([]),
            ]),
        ])
        let backend = CoreDeviceSessionTestBackend(
            remoteConnections: [
                applicationConnection,
                processConnection,
            ]
        )
        let session = DeviceSession(backend: backend)

        let terminated = try await session.terminateApplication(
            bundleIdentifier: "com.example.developer-app"
        )

        XCTAssertFalse(terminated)
    }
}

/// Device-session backend that exposes only direct CoreDevice services.
private final class CoreDeviceSessionTestBackend: DeviceSessionBackend {
    /// Connections returned in service-open order.
    private var remoteConnections: [DeviceConnection]

    /// Lockdown-compatible services requested by the session.
    private(set) var startedLockdownServices: [String] = []

    /// Direct RSD services requested by the session.
    private(set) var startedRemoteServices: [String] = []

    /// Creates a backend with deterministic direct-service connections.
    init(remoteConnections: [DeviceConnection]) {
        self.remoteConnections = remoteConnections
    }

    /// Returns minimal device information for protocol conformance.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfo(values: [:])
    }

    /// Records and rejects unexpected Lockdown-compatible service access.
    func startService(
        named serviceName: String,
        escrowBag _: Data?
    ) async throws -> DeviceConnection {
        startedLockdownServices.append(serviceName)
        throw RorkDeviceError.protocolViolation(
            "Unexpected Lockdown service \(serviceName)."
        )
    }

    /// Returns the next direct CoreDevice service connection.
    func startRemoteService(
        named serviceName: String
    ) async throws -> DeviceConnection {
        startedRemoteServices.append(serviceName)
        guard !remoteConnections.isEmpty else {
            throw RorkDeviceError.transport(
                "No CoreDevice test connection remains."
            )
        }
        return remoteConnections.removeFirst()
    }
}

/// Encodes app-service outputs after a complete RemoteXPC channel handshake.
private func coreDeviceAppServiceConnection(
    responses: [RemoteXPCValue]
) throws -> FakeConnection {
    var inbound = try remoteXPCSessionHandshakeInbound()
    for (index, output) in responses.enumerated() {
        let response = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": output,
            ]),
            flags: 0x00020101,
            messageIdentifier: UInt64(index + 1)
        )
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: response
            )
        )
    }
    return FakeConnection(inbound: inbound)
}
