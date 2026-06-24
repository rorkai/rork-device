import Foundation

/// One process entry returned by CoreDevice's app service.
struct CoreDeviceProcess: Equatable, Sendable {
    /// Positive process identifier assigned by iOS.
    let identifier: Int

    /// Device-side path of the running executable.
    let executablePath: String
}

/// One installed application returned by CoreDevice's app service.
///
/// The bundle path is retained internally so process-control workflows can
/// associate an executable with its containing application without guessing
/// the executable name.
struct CoreDeviceApplication: Equatable, Sendable {
    /// Stable bundle identifier used by launch and uninstall operations.
    let bundleIdentifier: String

    /// Human-readable application name reported by CoreDevice.
    let displayName: String

    /// Absolute path of the installed `.app` bundle on the device.
    let bundlePath: String

    /// Marketing version, when the application declares one.
    let version: String?

    /// Build version, when the application declares one.
    let buildVersion: String?

    /// Whether the application was installed for development.
    let isDeveloperApplication: Bool

    /// Whether Apple ships the application as first-party software.
    let isFirstParty: Bool

    /// Whether iOS classifies the application as internal software.
    let isInternal: Bool

    /// Tests whether this application belongs to an InstallationProxy class.
    ///
    /// CoreDevice reports independent first-party and internal flags rather
    /// than InstallationProxy's `ApplicationType` string.
    func matches(_ type: ApplicationType) -> Bool {
        switch type {
        case .user:
            return !isFirstParty && !isInternal
        case .system:
            return isFirstParty && !isInternal
        case .internalApplications:
            return isInternal
        case .all:
            return true
        }
    }

}

/// RemoteXPC client for `com.apple.coredevice.appservice`.
///
/// The service launches applications and controls already-running processes on
/// current iOS versions. Its request envelope is shared by CoreDevice features,
/// while each feature supplies a distinct value under `CoreDevice.input`.
final class CoreDeviceApplicationService {
    /// Exact service name advertised by Remote Service Discovery.
    static let serviceName = "com.apple.coredevice.appservice"

    /// RemoteXPC flag marking CoreDevice request messages.
    private static let requestFlag: UInt32 = 0x00010000

    /// CoreDevice protocol version sent by current desktop tooling.
    private static let coreDeviceVersion = RemoteXPCValue.dictionary([
        "components": .array([
            .uint64(0x15c),
            .uint64(0x1),
            .uint64(0),
            .uint64(0),
            .uint64(0),
        ]),
        "originalComponentsCount": .int64(2),
        "stringValue": .string("348.1"),
    ])

    /// Live RemoteXPC channel owned by this service client.
    private let connection: RemoteXPCConnection

    /// Stable identifier included in every request on this service connection.
    private let deviceIdentifier = UUID().uuidString

    /// Creates a client around an initialized RemoteXPC channel.
    private init(connection: RemoteXPCConnection) {
        self.connection = connection
    }

    /// Starts RemoteXPC on a raw app-service stream and assumes ownership.
    ///
    /// - Parameter connection: Direct RSD service connection without shim
    ///   check-in framing.
    /// - Returns: An initialized app-service client.
    static func open(
        over connection: DeviceConnection
    ) async throws -> CoreDeviceApplicationService {
        CoreDeviceApplicationService(
            connection: try await RemoteXPCConnection.open(over: connection)
        )
    }

    /// Lists installed applications visible to CoreDevice.
    ///
    /// All device categories are requested because process-control workflows
    /// need to resolve user, system, and internal bundle paths.
    ///
    /// - Parameter type: Public application class to retain.
    /// - Returns: CoreDevice metadata for matching installed applications.
    func applications(
        matching type: ApplicationType
    ) async throws -> [CoreDeviceApplication] {
        let output = try await perform(
            feature: "com.apple.coredevice.feature.listapps",
            input: .dictionary([
                "includeAppClips": .bool(true),
                "includeDefaultApps": .bool(true),
                "includeHiddenApps": .bool(true),
                "includeInternalApps": .bool(true),
                "includeRemovableApps": .bool(true),
            ])
        )
        guard case let .array(entries) = output else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice app-list response is not an array."
            )
        }

        return try entries.map { entry in
            guard let values = entry.dictionaryValue,
                  let bundleIdentifier =
                    values["bundleIdentifier"]?.stringValue,
                  !bundleIdentifier.isEmpty,
                  let bundlePath = values["path"]?.stringValue,
                  !bundlePath.isEmpty else {
                throw RorkDeviceError.protocolViolation(
                    "CoreDevice app-list response contains an invalid application entry."
                )
            }
            let displayName = values["name"]?.stringValue
                ?? bundleIdentifier
            return CoreDeviceApplication(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                bundlePath: bundlePath,
                version: values["version"]?.stringValue,
                buildVersion: values["bundleVersion"]?.stringValue,
                isDeveloperApplication:
                    values["isDeveloperApp"]?.booleanValue ?? false,
                isFirstParty:
                    values["isFirstParty"]?.booleanValue ?? false,
                isInternal:
                    values["isInternal"]?.booleanValue ?? false
            )
        }.filter { $0.matches(type) }
    }

    /// Launches an installed application through CoreDevice.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier of an installed application.
    ///   - options: Arguments, environment, and replacement behavior.
    /// - Returns: Process identifier assigned to the launched application.
    func launchApplication(
        bundleIdentifier: String,
        options: ApplicationLaunchOptions
    ) async throws -> Int {
        let platformSpecificOptions = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](),
            format: .binary,
            options: 0
        )
        let response = try await perform(
            feature: "com.apple.coredevice.feature.launchapplication",
            input: .dictionary([
                "applicationSpecifier": .dictionary([
                    "bundleIdentifier": .dictionary([
                        "_0": .string(bundleIdentifier),
                    ]),
                ]),
                "options": .dictionary([
                    "arguments": .array(
                        options.arguments.map(RemoteXPCValue.string)
                    ),
                    "environmentVariables": .dictionary(
                        options.environment.mapValues(
                            RemoteXPCValue.string
                        )
                    ),
                    "platformSpecificOptions": .data(
                        platformSpecificOptions
                    ),
                    "standardIOUsesPseudoterminals": .bool(true),
                    "startStopped": .bool(false),
                    "terminateExisting": .bool(
                        options.terminateExistingProcess
                    ),
                    "user": .dictionary([
                        "active": .bool(true),
                    ]),
                    "workingDirectory": .null,
                ]),
                "standardIOIdentifiers": .dictionary([:]),
            ])
        )
        guard let output = response.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice launch response output is not a dictionary."
            )
        }
        guard let processToken = output["processToken"]?.dictionaryValue,
              let processIdentifier =
                processToken["processIdentifier"]?.integerValue,
              processIdentifier > 0 else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice launch response does not contain a valid process identifier."
            )
        }
        return processIdentifier
    }

    /// Lists processes visible to CoreDevice's app service.
    ///
    /// - Returns: Process identifiers and executable paths reported by iOS.
    func runningProcesses() async throws -> [CoreDeviceProcess] {
        let response = try await perform(
            feature: "com.apple.coredevice.feature.listprocesses",
            input: .null
        )
        guard let output = response.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice process-list response output is not a dictionary."
            )
        }
        guard case let .array(tokens)? = output["processTokens"] else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice process-list response does not contain process tokens."
            )
        }
        return try tokens.map { token in
            guard let values = token.dictionaryValue,
                  let identifier =
                    values["processIdentifier"]?.integerValue,
                  identifier > 0,
                  let executableURL =
                    values["executableURL"]?.dictionaryValue,
                  let executablePath =
                    executableURL["relative"]?.stringValue,
                  !executablePath.isEmpty else {
                throw RorkDeviceError.protocolViolation(
                    "CoreDevice process-list response contains an invalid process token."
                )
            }
            return CoreDeviceProcess(
                identifier: identifier,
                executablePath: executablePath
            )
        }
    }

    /// Sends a POSIX signal to one running process.
    ///
    /// - Parameters:
    ///   - signal: Numeric signal value understood by the device.
    ///   - processIdentifier: Positive identifier returned by
    ///     `runningProcesses()` or `launchApplication`.
    func sendSignal(
        _ signal: Int32,
        to processIdentifier: Int
    ) async throws {
        guard processIdentifier > 0 else {
            throw RorkDeviceError.invalidInput(
                "Process identifier must be positive."
            )
        }
        _ = try await perform(
            feature: "com.apple.coredevice.feature.sendsignaltoprocess",
            input: .dictionary([
                "process": .dictionary([
                    "processIdentifier": .int64(
                        Int64(processIdentifier)
                    ),
                ]),
                "signal": .int64(Int64(signal)),
            ])
        )
    }

    /// Closes the owned RemoteXPC service connection.
    func close() {
        connection.close()
    }

    /// Sends one CoreDevice feature request and validates its response envelope.
    ///
    /// Device-side errors are surfaced before feature-specific output parsing
    /// so callers never mistake an error dictionary for a successful response.
    private func perform(
        feature: String,
        input: RemoteXPCValue
    ) async throws -> RemoteXPCValue {
        try await connection.send(
            request(feature: feature, input: input),
            additionalFlags: Self.requestFlag
        )
        let response = try await connection.receive(on: .reply)
        guard let root = response.value?.dictionaryValue else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice app service returned a response without a dictionary body."
            )
        }
        if let error = root["CoreDevice.error"] {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice app service rejected \(feature): \(String(describing: error))."
            )
        }
        guard let output = root["CoreDevice.output"] else {
            throw RorkDeviceError.protocolViolation(
                "CoreDevice app service response for \(feature) does not contain CoreDevice.output."
            )
        }
        return output
    }

    /// Builds the common CoreDevice request envelope for one feature call.
    private func request(
        feature: String,
        input: RemoteXPCValue
    ) -> RemoteXPCValue {
        .dictionary([
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(0),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.coreDeviceVersion": Self.coreDeviceVersion,
            "CoreDevice.deviceIdentifier": .string(deviceIdentifier),
            "CoreDevice.featureIdentifier": .string(feature),
            "CoreDevice.input": input,
            "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
        ])
    }
}
