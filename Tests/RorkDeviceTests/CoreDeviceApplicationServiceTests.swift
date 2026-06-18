import Foundation
import XCTest
@testable import RorkDevice

final class CoreDeviceApplicationServiceTests: XCTestCase {
    func testListsDeveloperApplicationsWithTheirBundlePaths() async throws {
        let response = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": .array([
                    .dictionary([
                        "bundleIdentifier": .string(
                            "com.example.developer-app"
                        ),
                        "name": .string("Example Developer App"),
                        "path": .string(
                            "/private/var/containers/Bundle/Application/UUID/Example Developer App.app"
                        ),
                        "version": .string("1.0.18"),
                        "bundleVersion": .string("20"),
                        "isDeveloperApp": .bool(true),
                        "isFirstParty": .bool(false),
                        "isInternal": .bool(false),
                    ]),
                ]),
            ]),
            flags: 0x00020101,
            messageIdentifier: 1
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: response
            )
        )
        let connection = FakeConnection(inbound: inbound)
        let service = try await CoreDeviceApplicationService.open(
            over: connection
        )
        defer {
            service.close()
        }

        let applications = try await service.applications(matching: .all)

        XCTAssertEqual(applications, [
            CoreDeviceApplication(
                bundleIdentifier: "com.example.developer-app",
                displayName: "Example Developer App",
                bundlePath:
                    "/private/var/containers/Bundle/Application/UUID/Example Developer App.app",
                version: "1.0.18",
                buildVersion: "20",
                isDeveloperApplication: true,
                isFirstParty: false,
                isInternal: false
            ),
        ])
        let request = try XCTUnwrap(
            sentRemoteXPCMessages(in: connection).last
        )
        XCTAssertEqual(
            request.value?.dictionaryValue?[
                "CoreDevice.featureIdentifier"
            ]?.stringValue,
            "com.apple.coredevice.feature.listapps"
        )
        let input = try XCTUnwrap(
            request.value?.dictionaryValue?[
                "CoreDevice.input"
            ]?.dictionaryValue
        )
        XCTAssertEqual(input["includeAppClips"], .bool(true))
        XCTAssertEqual(input["includeRemovableApps"], .bool(true))
        XCTAssertEqual(input["includeHiddenApps"], .bool(true))
        XCTAssertEqual(input["includeInternalApps"], .bool(true))
        XCTAssertEqual(input["includeDefaultApps"], .bool(true))
    }

    func testLaunchesApplicationAndReturnsProcessIdentifier() async throws {
        let response = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processToken": .dictionary([
                        "processIdentifier": .int64(4_242),
                    ]),
                ]),
            ]),
            flags: 0x00020101,
            messageIdentifier: 1
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        inbound.append(
            remoteXPCTestFrame(
                type: 0x00,
                streamIdentifier: 3,
                payload: response
            )
        )
        let connection = FakeConnection(inbound: inbound)
        let service = try await CoreDeviceApplicationService.open(
            over: connection
        )
        defer {
            service.close()
        }

        let processIdentifier = try await service.launchApplication(
            bundleIdentifier: "app.rork.example",
            options: ApplicationLaunchOptions(
                arguments: ["--diagnostic"],
                environment: ["RORK_MODE": "test"],
                terminateExistingProcess: true
            )
        )

        XCTAssertEqual(processIdentifier, 4_242)
        let request = try XCTUnwrap(
            sentRemoteXPCMessages(in: connection).last
        )
        XCTAssertEqual(request.flags, 0x00010101)
        let root = try XCTUnwrap(request.value?.dictionaryValue)
        XCTAssertEqual(
            root["CoreDevice.featureIdentifier"]?.stringValue,
            "com.apple.coredevice.feature.launchapplication"
        )
        let input = try XCTUnwrap(
            root["CoreDevice.input"]?.dictionaryValue
        )
        let options = try XCTUnwrap(input["options"]?.dictionaryValue)
        XCTAssertEqual(
            options["arguments"],
            .array([.string("--diagnostic")])
        )
        XCTAssertEqual(
            options["environmentVariables"],
            .dictionary(["RORK_MODE": .string("test")])
        )
        XCTAssertEqual(options["terminateExisting"], .bool(true))
    }

    func testListsProcessesAndSendsTerminationSignal() async throws {
        let processesResponse = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processTokens": .array([
                        .dictionary([
                            "processIdentifier": .int64(7),
                            "executableURL": .dictionary([
                                "relative": .string(
                                    "/private/var/containers/Bundle/Application/App/Example"
                                ),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            flags: 0x00020101,
            messageIdentifier: 1
        )
        let signalResponse = try RemoteXPCMessageCodec.encode(
            value: .dictionary([
                "CoreDevice.output": .dictionary([:]),
            ]),
            flags: 0x00020101,
            messageIdentifier: 2
        )
        var inbound = try remoteXPCSessionHandshakeInbound()
        for response in [processesResponse, signalResponse] {
            inbound.append(
                remoteXPCTestFrame(
                    type: 0x00,
                    streamIdentifier: 3,
                    payload: response
                )
            )
        }
        let connection = FakeConnection(inbound: inbound)
        let service = try await CoreDeviceApplicationService.open(
            over: connection
        )
        defer {
            service.close()
        }

        let processes = try await service.runningProcesses()
        try await service.sendSignal(9, to: 7)

        XCTAssertEqual(processes, [
            CoreDeviceProcess(
                identifier: 7,
                executablePath:
                    "/private/var/containers/Bundle/Application/App/Example"
            ),
        ])
        let requests = sentRemoteXPCMessages(in: connection)
        XCTAssertEqual(
            requests.suffix(2).compactMap {
                $0.value?.dictionaryValue?[
                    "CoreDevice.featureIdentifier"
                ]?.stringValue
            },
            [
                "com.apple.coredevice.feature.listprocesses",
                "com.apple.coredevice.feature.sendsignaltoprocess",
            ]
        )
        let signalInput = try XCTUnwrap(
            requests.last?.value?.dictionaryValue?[
                "CoreDevice.input"
            ]?.dictionaryValue
        )
        XCTAssertEqual(signalInput["signal"], .int64(9))
        XCTAssertEqual(
            signalInput["process"]?.dictionaryValue?[
                "processIdentifier"
            ],
            .int64(7)
        )
    }
}

private func sentRemoteXPCMessages(
    in connection: FakeConnection
) -> [RemoteXPCMessage] {
    connection.sent.compactMap { frame in
        guard frame.count >= 9, frame[3] == 0x00 else {
            return nil
        }
        let streamIdentifier =
            (UInt32(frame[5]) << 24)
            | (UInt32(frame[6]) << 16)
            | (UInt32(frame[7]) << 8)
            | UInt32(frame[8])
        guard streamIdentifier == 1 else {
            return nil
        }
        return try? RemoteXPCMessageCodec.decodeFirstMessage(
            from: Data(frame.dropFirst(9))
        )?.message
    }
}
