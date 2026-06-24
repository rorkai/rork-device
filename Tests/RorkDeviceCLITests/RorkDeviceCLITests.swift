import RorkDevice
import XCTest
@testable import RorkDeviceCLI

final class RorkDeviceCLITests: XCTestCase {
    func testHelpMentionsCoreCommands() {
        let help = RorkDeviceCommand.helpMessage()

        XCTAssertTrue(help.contains("rorkdevice"))
        XCTAssertTrue(help.contains("list"))
        XCTAssertTrue(help.contains("watch"))
        XCTAssertTrue(help.contains("files"))
        XCTAssertTrue(help.contains("install"))
        XCTAssertTrue(help.contains("launch"))
        XCTAssertTrue(help.contains("terminate"))
        XCTAssertTrue(help.contains("profiles"))
        XCTAssertTrue(help.contains("pairing"))
        XCTAssertTrue(help.contains("developer-mode"))
        XCTAssertTrue(help.contains("image"))
        XCTAssertTrue(help.contains("remote-pairing"))
        XCTAssertTrue(help.contains("tunnel"))
    }

    func testImageMountCommandParsesRestorePath() throws {
        let command = try ImageMount.parse([
            "--pairing-record", "pairing.plist",
            "--path", "/tmp/DDI/Restore",
            "--json",
        ])

        XCTAssertEqual(
            command.connection.pairingRecord,
            "pairing.plist"
        )
        XCTAssertEqual(command.restorePath, "/tmp/DDI/Restore")
        XCTAssertTrue(command.json)
    }

    func testImageAutoCommandParsesAuthenticatedSource() throws {
        let command = try ImageAuto.parse([
            "--pairing-record", "pairing.plist",
            "--archive-url", "https://example.com/ddi.zip",
            "--sha256", String(repeating: "a", count: 64),
            "--cache-directory", "/tmp/ddi-cache",
            "--json",
        ])

        XCTAssertEqual(
            command.archiveURL,
            "https://example.com/ddi.zip"
        )
        XCTAssertEqual(
            command.sha256,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(command.cacheDirectory, "/tmp/ddi-cache")
        XCTAssertTrue(command.json)
    }

    func testImageAutoCommandRejectsInsecureSource() {
        XCTAssertThrowsError(try ImageAuto.parse([
            "--pairing-record", "pairing.plist",
            "--archive-url", "http://example.com/ddi.zip",
            "--sha256", String(repeating: "a", count: 64),
        ]))
    }

    func testDeveloperDiskImageMountJSONIncludesTunnelRestart() throws {
        let data = try developerDiskImageMountJSON(
            DeveloperDiskImageMountResult(
                status: .mounted,
                ticketSource: .appleTSS
            )
        )
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(output["status"] as? String, "mounted")
        XCTAssertEqual(
            output["ticketSource"] as? String,
            "appleTSS"
        )
        XCTAssertEqual(
            output["requiresTunnelRestart"] as? Bool,
            true
        )
    }

    func testInstallCommandParsesArguments() throws {
        let command = try Install.parse([
            "--pairing-record", "pairing.plist",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.ipaPath, "App.ipa")
        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
    }

    func testListCommandParsesUSBFilter() throws {
        let command = try List.parse([
            "--usb",
            "--details",
            "--json",
        ])

        XCTAssertTrue(command.usb)
        XCTAssertTrue(command.details)
        XCTAssertTrue(command.json)
    }

    func testUSBFilterAcceptsOnlyUSBDevices() {
        let usbDevice = Device(
            identifier: "usb-device",
            connection: .usbmux(deviceID: 1),
            properties: ["ConnectionType": "USB"]
        )
        let networkDevice = Device(
            identifier: "network-device",
            connection: .usbmux(deviceID: 2),
            properties: ["ConnectionType": "Network"]
        )

        XCTAssertTrue(isUSBDevice(usbDevice))
        XCTAssertFalse(isUSBDevice(networkDevice))
    }

    func testDeviceListJSONEncodesIdentifiers() throws {
        let data = try deviceListJSON([
            Device(
                identifier: "device-1",
                connection: .usbmux(deviceID: 1)
            ),
            Device(
                identifier: "device-2",
                connection: .usbmux(deviceID: 2)
            ),
        ])

        let identifiers = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String]
        )

        XCTAssertEqual(identifiers, ["device-1", "device-2"])
    }

    func testDetailedDeviceListJSONPreservesConnectionMetadata() throws {
        let data = try detailedDeviceListJSON([
            Device(
                identifier: "device-1",
                connection: .usbmux(deviceID: 7),
                properties: [
                    "ConnectionType": "USB",
                    "ProductID": "1234",
                ]
            ),
        ])
        let entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [[String: Any]]
        )

        XCTAssertEqual(entries.first?["udid"] as? String, "device-1")
        XCTAssertEqual(
            entries.first?["connectionType"] as? String,
            "usb"
        )
        XCTAssertEqual(
            (entries.first?["properties"] as? [String: String])?[
                "ProductID"
            ],
            "1234"
        )
    }

    func testDeviceEventJSONEncodesAttachMetadata() throws {
        let data = try deviceEventJSON(.attached(Device(
            identifier: "device-1",
            connection: .usbmux(deviceID: 7),
            properties: ["ConnectionType": "Network"]
        )))
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(event["event"] as? String, "attached")
        XCTAssertEqual(event["udid"] as? String, "device-1")
        XCTAssertEqual(
            event["connectionType"] as? String,
            "network"
        )
    }

    func testInstallCommandParsesUserspaceRemoteServiceRoute() throws {
        let command = try Install.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ])

        XCTAssertEqual(
            command.connection.userspaceDeviceAddress,
            "fd92:fbe0:acf3::2"
        )
        XCTAssertEqual(
            command.connection.userspaceGatewayHost,
            "127.0.0.1"
        )
        XCTAssertEqual(
            command.connection.userspaceGatewayPort,
            60_112
        )
        XCTAssertEqual(
            command.connection.remoteServiceDiscoveryPort,
            54_130
        )
    }

    func testInstallCommandRejectsIncompleteUserspaceRoute() {
        XCTAssertThrowsError(try Install.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ]))
    }

    func testInstallCommandRejectsBlankUserspaceDeviceAddress() {
        XCTAssertThrowsError(try Install.parse([
            "--userspace-device-address", " \n ",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "App.ipa",
            "--bundle-identifier", "com.example.app",
        ]))
    }

    func testLaunchCommandParsesProcessOptions() throws {
        let command = try Launch.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "--kill-existing",
            "--arg=--diagnostic",
            "--env=RORK_MODE=test",
            "com.example.app",
        ])

        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
        XCTAssertTrue(command.killExisting)
        XCTAssertEqual(command.arguments, ["--diagnostic"])
        XCTAssertEqual(command.environment, ["RORK_MODE=test"])
    }

    func testLaunchCommandRequiresAUserspaceRoute() {
        XCTAssertThrowsError(try Launch.parse([
            "--pairing-record", "pairing.plist",
            "com.example.app",
        ]))
    }

    func testTerminateCommandParsesBundleIdentifier() throws {
        let command = try Terminate.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "com.example.app",
        ])

        XCTAssertEqual(command.bundleIdentifier, "com.example.app")
    }

    func testTerminateCommandRequiresAUserspaceRoute() {
        XCTAssertThrowsError(try Terminate.parse([
            "--pairing-record", "pairing.plist",
            "com.example.app",
        ]))
    }

    func testAppsListCommandParsesApplicationType() throws {
        let command = try AppsList.parse([
            "--pairing-record", "pairing.plist",
            "--type", "all",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.type, .all)
    }

    func testAppsListCommandParsesJSONOutput() throws {
        let command = try AppsList.parse([
            "--pairing-record", "pairing.plist",
            "--json",
        ])

        XCTAssertTrue(command.json)
    }

    func testAppsListCommandParsesProtocolApplicationType() throws {
        let command = try AppsList.parse([
            "--pairing-record", "pairing.plist",
            "--type", "Any",
        ])

        XCTAssertEqual(command.type, .all)
    }

    func testInstalledApplicationListJSONPreservesVersionMetadata() throws {
        let data = try installedApplicationListJSON([
            InstalledApplication(values: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleDisplayName": "Example",
                "CFBundleShortVersionString": "2.3.0",
                "CFBundleVersion": "45",
            ]),
        ])
        let applications = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: String]]
        )

        XCTAssertEqual(applications, [[
            "bundleIdentifier": "com.example.app",
            "displayName": "Example",
            "version": "2.3.0",
            "buildVersion": "45",
        ]])
    }

    func testInstalledApplicationListJSONOmitsUnavailableMetadata() throws {
        let data = try installedApplicationListJSON([
            InstalledApplication(values: [
                "CFBundleIdentifier": "com.example.app",
            ]),
        ])
        let applications = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let application = try XCTUnwrap(applications.first)

        XCTAssertEqual(
            application["bundleIdentifier"] as? String,
            "com.example.app"
        )
        XCTAssertNil(application["displayName"])
        XCTAssertNil(application["version"])
        XCTAssertNil(application["buildVersion"])
    }

    func testInfoCommandParsesDirectEndpoint() throws {
        let command = try Info.parse([
            "--host", "127.0.0.1",
            "--port", "62079",
            "--pairing-record", "pairing.plist",
            "--json",
        ])

        XCTAssertEqual(command.connection.host, "127.0.0.1")
        XCTAssertEqual(command.connection.port, 62079)
        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertTrue(command.json)
    }

    func testInfoCommandRejectsHostAndUDIDTogether() {
        XCTAssertThrowsError(try Info.parse([
            "--host", "127.0.0.1",
            "--udid", "device-1",
            "--pairing-record", "pairing.plist",
        ]))
    }

    func testInfoCommandRejectsPortWithoutHost() {
        XCTAssertThrowsError(try Info.parse([
            "--port", "62079",
            "--pairing-record", "pairing.plist",
        ]))
    }

    func testLockdownInfoJSONPreservesScalarLockdownKeys() throws {
        let info = DeviceInfo(values: [
            "UniqueDeviceID": "device-1",
            "DeviceClass": "iPhone",
            "ProductVersion": "26.5.1",
        ])

        let data = try lockdownInfoJSON(info)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(values["UniqueDeviceID"], "device-1")
        XCTAssertEqual(values["DeviceClass"], "iPhone")
        XCTAssertEqual(values["ProductVersion"], "26.5.1")
    }

    func testPairingValidateCommandParsesDeviceIdentifier() throws {
        let command = try PairingValidate.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
    }

    func testPairingDiagnoseCommandParsesJSONOutput() throws {
        let command = try PairingDiagnose.parse([
            "--udid", "device-1",
            "--json",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
        XCTAssertTrue(command.json)
    }

    func testPairingDiagnosticProfilesContinueAfterFailure() async {
        let attempts = await runPairingDiagnosticProfiles { profile in
            PairingDiagnosticAttempt(
                profile: profile.rawValue,
                succeeded: profile != .standard,
                phase: profile == .standard
                    ? PairingDiagnosticPhase.tlsHandshake.rawValue
                    : PairingDiagnosticPhase.complete.rawValue,
                error: profile == .standard ? "handshake failed" : nil
            )
        }

        XCTAssertEqual(
            attempts.map(\.profile),
            LockdownTLSProfile.allCases.map(\.rawValue)
        )
        XCTAssertEqual(attempts.first?.error, "handshake failed")
        XCTAssertTrue(attempts.dropFirst().allSatisfy(\.succeeded))
    }

    func testPairingDiagnosticJSONOmitsPrivatePairingMaterial() throws {
        let record = try makePairingDiagnosticTestRecord()
        let report = PairingDiagnosticReport(
            deviceIdentifier: "device-1",
            pairingRecord: pairingRecordDiagnostic(record),
            attempts: [
                PairingDiagnosticAttempt(
                    profile: LockdownTLSProfile.standard.rawValue,
                    succeeded: false,
                    phase: PairingDiagnosticPhase.tlsHandshake.rawValue,
                    error: "TLSV1_ALERT_BAD_CERTIFICATE"
                ),
            ]
        )

        let data = try pairingDiagnosticJSON(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let pairing = try XCTUnwrap(
            object["pairingRecord"] as? [String: Any]
        )
        let hostCertificate = try XCTUnwrap(
            pairing["hostCertificate"] as? [String: Any]
        )

        XCTAssertEqual(hostCertificate["byteCount"] as? Int, 16)
        XCTAssertNotNil(hostCertificate["sha256"] as? String)
        XCTAssertNil(pairing["hostPrivateKey"])
        XCTAssertNil(pairing["rootPrivateKey"])
        XCTAssertNil(pairing["escrowBag"])
    }

    func testPairingDiagnosticTextIncludesRedactedCertificateMetadata() throws {
        let record = try makePairingDiagnosticTestRecord()
        let report = PairingDiagnosticReport(
            deviceIdentifier: "device-1",
            pairingRecord: pairingRecordDiagnostic(record),
            attempts: []
        )
        let hostCertificate = try XCTUnwrap(
            report.pairingRecord.hostCertificate
        )

        let output = pairingDiagnosticText(report)

        XCTAssertTrue(output.contains("Pairing record:"))
        XCTAssertTrue(
            output.contains(
                "hostCertificate: \(hostCertificate.encoding), \(hostCertificate.byteCount) bytes, sha256=\(hostCertificate.sha256)"
            )
        )
        XCTAssertFalse(output.contains("private-key"))
        XCTAssertFalse(output.contains("root-private-key"))
        XCTAssertFalse(output.contains("escrow"))
    }

    func testPairingEstablishCommandParsesDeviceIdentifierAndTimeout() throws {
        let command = try PairingEstablish.parse([
            "--udid", "device-1",
            "--trust-timeout", "90",
        ])

        XCTAssertEqual(command.udid, "device-1")
        XCTAssertEqual(command.trustTimeout, 90)
    }

    func testPairingActivationRetriesAfterTransientSecureSessionFailure()
        async throws
    {
        var attempts = 0
        var delays: [Duration] = []

        let result = try await waitForSavedPairingActivation(
            attemptDelays: [
                .zero,
                .milliseconds(25),
            ],
            sleep: { delay in
                delays.append(delay)
            },
            onRetry: { _ in },
            attempt: {
                attempts += 1
                if attempts == 1 {
                    throw RorkDeviceError.secureSession(
                        "TLS handshake failed: EOF during handshake"
                    )
                }
                return "active-session"
            }
        )

        XCTAssertEqual(result, "active-session")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delays, [.milliseconds(25)])
    }

    func testPairingActivationRetryWindowCoversDelayedTrustPublication() {
        XCTAssertEqual(savedPairingActivationAttemptDelays, [
            .zero,
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8),
        ])
    }

    func testPairingActivationDoesNotRetryProtocolFailure() async throws {
        var attempts = 0
        let failure = RorkDeviceError.protocolViolation(
            "Lockdown returned malformed session data."
        )

        do {
            try await waitForSavedPairingActivation(
                attemptDelays: [
                    .zero,
                    .milliseconds(25),
                ],
                sleep: { _ in },
                onRetry: { _ in },
                attempt: {
                    attempts += 1
                    throw failure
                }
            )
            XCTFail("Expected the protocol failure to leave immediately.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, failure)
        }

        XCTAssertEqual(attempts, 1)
    }

    func testPairingActivationThrowsTheFinalRetryableFailure() async {
        let firstFailure = RorkDeviceError.secureSession(
            "The first fresh Lockdown session closed."
        )
        let finalFailure = RorkDeviceError.transport(
            "The final fresh Lockdown connection failed."
        )
        var attempts = 0
        var retriedFailures: [RorkDeviceError] = []

        do {
            _ = try await waitForSavedPairingActivation(
                attemptDelays: [.zero, .zero],
                sleep: { _ in },
                onRetry: { error in
                    if let error = error as? RorkDeviceError {
                        retriedFailures.append(error)
                    }
                },
                attempt: {
                    attempts += 1
                    throw attempts == 1 ? firstFailure : finalFailure
                }
            )
            XCTFail("Expected the final retryable failure.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, finalFailure)
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(retriedFailures, [firstFailure])
    }

    func testPairingExportCommandParsesOptionalOutputPath() throws {
        let command = try PairingExport.parse([
            "--udid", "device-1",
            "--output", "pairing.plist",
        ])

        XCTAssertEqual(command.udid, "device-1")
        XCTAssertEqual(command.outputPath, "pairing.plist")
    }

    func testPairingExportDefaultsToStandardOutput() throws {
        let command = try PairingExport.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.udid, "device-1")
        XCTAssertNil(command.outputPath)
    }

    func testPairingRemoveCommandParsesDeviceIdentifier() throws {
        let command = try PairingRemove.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.udid, "device-1")
    }

    func testPairingHelpMentionsLifecycleCommands() {
        let help = PairingCommand.helpMessage()

        XCTAssertTrue(help.contains("establish"))
        XCTAssertTrue(help.contains("export"))
        XCTAssertTrue(help.contains("remove"))
        XCTAssertTrue(help.contains("validate"))
        XCTAssertTrue(help.contains("diagnose"))
        XCTAssertTrue(help.contains("enable-wireless"))
    }

    func testPairingEnableWirelessCommandParsesDeviceIdentifier() throws {
        let command = try PairingEnableWireless.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
    }

    func testPairingValidationRejectsUnexpectedDeviceIdentifier() {
        let info = DeviceInfo(values: [
            "UniqueDeviceID": "device-2",
        ])

        XCTAssertThrowsError(
            try validatePairingIdentity(
                info,
                expectedDeviceIdentifier: "device-1"
            )
        )
    }

    func testPairingValidationRequiresDeviceIdentifierFromLockdown() {
        let info = DeviceInfo(values: [:])

        XCTAssertThrowsError(
            try validatePairingIdentity(
                info,
                expectedDeviceIdentifier: "device-1"
            )
        )
    }

    func testDeveloperModeRevealCommandParsesDeviceIdentifier() throws {
        let command = try DeveloperModeReveal.parse([
            "--udid", "device-1",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
    }

    func testDeveloperModeStatusCommandParsesJSONOutput() throws {
        let command = try DeveloperModeStatus.parse([
            "--udid", "device-1",
            "--json",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
        XCTAssertTrue(command.json)
    }

    func testProfilesCopyCommandParsesOutputDirectoryAndLegacyMode() throws {
        let command = try ProfilesCopy.parse([
            "--pairing-record", "pairing.plist",
            "--output-directory", "Profiles",
            "--legacy",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.outputDirectory, "Profiles")
        XCTAssertTrue(command.legacy)
    }

    func testProfilesRemoveCommandParsesIdentifier() throws {
        let command = try ProfilesRemove.parse([
            "--pairing-record", "pairing.plist",
            "profile-uuid",
        ])

        XCTAssertEqual(command.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.identifier, "profile-uuid")
    }

    func testRemotePairingTrustCommandParsesUserspaceTunnel() throws {
        let command = try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", "fd92:fbe0:acf3::2",
            "--discovery-port", "54130",
            "--gateway-port", "60112",
        ])

        XCTAssertEqual(command.identityPath, "selfIdentity.plist")
        XCTAssertEqual(command.deviceAddress, "fd92:fbe0:acf3::2")
        XCTAssertEqual(command.discoveryPort, 54_130)
        XCTAssertEqual(command.gatewayHost, "127.0.0.1")
        XCTAssertEqual(command.gatewayPort, 60_112)
    }

    func testRemotePairingTrustCommandRejectsBlankDeviceAddress() {
        XCTAssertThrowsError(try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", " \n ",
            "--discovery-port", "54130",
            "--gateway-port", "60112",
        ]))
    }

    func testRemotePairingTrustCommandRejectsBlankGatewayHost() {
        XCTAssertThrowsError(try RemotePairingTrustCommand.parse([
            "--identity", "selfIdentity.plist",
            "--device-address", "fd92:fbe0:acf3::2",
            "--discovery-port", "54130",
            "--gateway-host", " \n ",
            "--gateway-port", "60112",
        ]))
    }

    func testRemotePairingDiagnoseCommandParsesFreshLockdownSequence() throws {
        let command = try RemotePairingDiagnoseCommand.parse([
            "--udid", "device-1",
            "--identity", "selfIdentity.plist",
            "--refresh-lockdown-pairing",
            "--trust-timeout", "90",
            "--mtu", "1500",
            "--json",
        ])

        XCTAssertEqual(command.udid, "device-1")
        XCTAssertEqual(command.identityPath, "selfIdentity.plist")
        XCTAssertTrue(command.refreshLockdownPairing)
        XCTAssertEqual(command.trustTimeout, 90)
        XCTAssertEqual(command.maximumTransmissionUnit, 1_500)
        XCTAssertTrue(command.json)
        XCTAssertTrue(
            RemotePairingCommand.helpMessage().contains("diagnose")
        )
    }

    func testRemotePairingDiagnoseCommandRejectsOverflowingTrustTimeout() {
        XCTAssertThrowsError(try RemotePairingDiagnoseCommand.parse([
            "--identity", "selfIdentity.plist",
            "--trust-timeout", String(Double(Int64.max)),
        ]))
    }

    func testRemotePairingDiagnosticSkipsLockdownPairingWithoutRefresh()
        async
    {
        let recorder = RemotePairingDiagnosticRecorder()
        var didPair = false

        await performLockdownPairing(
            ifRequested: false,
            recorder: recorder
        ) {
            didPair = true
        }
        recorder.record(phase: .lockdownSession)
        let report = recorder.makeReport(
            deviceIdentifier: "device-1",
            identityIdentifier: "identity-1",
            didRefreshLockdownPairing: false
        )

        XCTAssertFalse(didPair)
        XCTAssertEqual(report.reachedPhases, [.lockdownSession])
    }

    func testRemotePairingDiagnosticReportPreservesEnrollmentStreamReset() throws {
        let recorder = RemotePairingDiagnosticRecorder()
        recorder.record(phase: .lockdownPairing)
        recorder.record(phase: .lockdownSession)
        recorder.record(phase: .coreDeviceTunnel)
        recorder.record(progress: .openingServiceDiscovery)
        recorder.record(progress: .openingPairingService)
        recorder.record(progress: .verifyingIdentity)
        recorder.record(progress: .enrollingIdentity)
        recorder.record(
            failure: RorkDeviceError.remoteXPCStreamReset(
                streamIdentifier: 1,
                errorCode: 5
            )
        )

        let report = recorder.makeReport(
            deviceIdentifier: "device-1",
            identityIdentifier: "identity-1",
            didRefreshLockdownPairing: true
        )
        let data = try remotePairingDiagnosticJSON(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.lastPhase, .enrollingIdentity)
        XCTAssertEqual(
            report.errorDescription,
            "RemoteXPC reset HTTP/2 stream 1 with error code 5."
        )
        XCTAssertEqual(object["identityIdentifier"] as? String, "identity-1")
        XCTAssertEqual(
            object["refreshedLockdownPairing"] as? Bool,
            true
        )
        XCTAssertEqual(
            object["lastPhase"] as? String,
            "enrolling-identity"
        )
        XCTAssertEqual(
            object["error"] as? String,
            report.errorDescription
        )
        XCTAssertNil(object["privateKey"])
        XCTAssertNil(object["pairingRecord"])
    }

    func testTunnelStartCommandParsesGatewayConfiguration() throws {
        let command = try TunnelStartCommand.parse([
            "--udid", "device-1",
            "--identity", "selfIdentity.plist",
            "--gateway-port", "60112",
            "--mtu", "1500",
        ])

        XCTAssertEqual(command.connection.udid, "device-1")
        XCTAssertEqual(command.identityPath, "selfIdentity.plist")
        XCTAssertEqual(command.gatewayHost, "127.0.0.1")
        XCTAssertEqual(command.gatewayPort, 60_112)
        XCTAssertEqual(command.maximumTransmissionUnit, 1_500)
    }

    func testTunnelStartCommandRejectsAnExistingUserspaceRoute() {
        XCTAssertThrowsError(try TunnelStartCommand.parse([
            "--userspace-device-address", "fd92:fbe0:acf3::2",
            "--userspace-gateway-port", "60112",
            "--remote-service-discovery-port", "54130",
            "--identity", "selfIdentity.plist",
        ]))
    }

    func testFilesListParsesHouseArrestOptions() throws {
        let command = try FilesList.parse([
            "--pairing-record", "pairing.plist",
            "--bundle-identifier", "com.example.app",
            "--container",
            "/Documents",
        ])

        XCTAssertEqual(command.access.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.access.bundleIdentifier, "com.example.app")
        XCTAssertTrue(command.access.container)
        XCTAssertEqual(command.path, "/Documents")
    }

    func testFilesListParsesJSONOutput() throws {
        let command = try FilesList.parse([
            "--pairing-record", "pairing.plist",
            "--json",
            "/Documents",
        ])

        XCTAssertTrue(command.json)
    }

    func testFileListJSONPreservesEntryNames() throws {
        let data = try fileListJSON([
            ".",
            "..",
            "Example.txt",
        ])
        let entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String]
        )

        XCTAssertEqual(entries, [".", "..", "Example.txt"])
    }

    func testFilesInfoParsesJSONOutput() throws {
        let command = try FilesInfo.parse([
            "--pairing-record", "pairing.plist",
            "--json",
            "/Documents/Example.txt",
        ])

        XCTAssertTrue(command.json)
    }

    func testFileInfoJSONPreservesAFCMetadata() throws {
        let data = try fileInfoJSON(AFCFileInfo(values: [
            "st_ifmt": "S_IFREG",
            "st_size": "42",
        ]))
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: String]
        )

        XCTAssertEqual(values, [
            "st_ifmt": "S_IFREG",
            "st_size": "42",
        ])
    }

    func testFilesRejectsContainerWithoutBundleIdentifier() {
        XCTAssertThrowsError(try FilesList.parse([
            "--pairing-record", "pairing.plist",
            "--container",
            "/Documents",
        ]))
    }

    func testFilesPushParsesLocalAndRemotePaths() throws {
        let command = try FilesPush.parse([
            "--pairing-record", "pairing.plist",
            "local.txt",
            "/Documents/local.txt",
        ])

        XCTAssertEqual(command.access.connection.pairingRecord, "pairing.plist")
        XCTAssertEqual(command.localPath, "local.txt")
        XCTAssertEqual(command.remotePath, "/Documents/local.txt")
    }
}

private func makePairingDiagnosticTestRecord() throws -> PairingRecord {
    try PairingRecord.parse(
        PropertyListSerialization.data(
            fromPropertyList: [
                "UDID": "device-1",
                "HostID": "host-1",
                "SystemBUID": "system-1",
                "DeviceCertificate": Data("device-certificate".utf8),
                "HostCertificate": Data("host-certificate".utf8),
                "HostPrivateKey": Data("private-key".utf8),
                "RootCertificate": Data("root-certificate".utf8),
                "RootPrivateKey": Data("root-private-key".utf8),
                "EscrowBag": Data("escrow".utf8),
            ],
            format: .binary,
            options: 0
        )
    )
}
