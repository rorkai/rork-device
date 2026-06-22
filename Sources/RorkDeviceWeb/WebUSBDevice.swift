#if canImport(JavaScriptKit)
import Foundation
import JavaScriptKit
import RorkDevice

/// Apple USB device selected through the browser permission prompt.
///
/// This type retains the browser-owned `USBDevice` handle on the main actor.
/// It does not open the device or claim an interface until `connect()` runs.
@MainActor
public final class WebUSBDevice {
    /// Product name reported by the USB device descriptor.
    public let productName: String?

    /// Serial number reported by the USB device descriptor.
    public let serialNumber: String?

    /// Browser-owned `USBDevice` object.
    private let device: JSObject

    /// Creates a typed wrapper around a browser-selected USB device.
    init(_ device: JSObject) {
        self.device = device
        productName = device.productName.string
        serialNumber = device.serialNumber.string
    }

    /// Opens and claims the device's direct-usbmux interface.
    ///
    /// The returned connection multiplexes Lockdown and all later service
    /// ports over the claimed bulk endpoints. The browser device remains open
    /// until `WebUSBDeviceConnection.close()` is called.
    ///
    /// - Returns: Connected device environment ready for pairing or an
    ///   authenticated Lockdown session.
    /// - Throws: Browser, descriptor, transfer, or direct-usbmux negotiation
    ///   errors.
    public func connect() async throws -> WebUSBDeviceConnection {
        if device.opened.boolean != true {
            try await perform("open")
        }

        do {
            guard
                let selection = selectDirectUSBMuxInterface(
                    from: try configurationDescriptors()
                )
            else {
                throw WebUSBError.directUSBMuxInterfaceUnavailable
            }

            try await selectConfigurationIfNeeded(
                selection.configurationValue
            )
            try await claimWebUSBInterface(
                using: {
                    try await perform(
                        "claimInterface",
                        arguments: [selection.interfaceNumber]
                    )
                },
                recoveringWith: {
                    try await perform("reset")
                    try await selectConfigurationIfNeeded(
                        selection.configurationValue
                    )
                }
            )
            try await perform(
                "selectAlternateInterface",
                arguments: [
                    selection.interfaceNumber,
                    selection.alternateSetting,
                ]
            )

            let pipe = WebUSBPipe(
                device: device,
                interfaceNumber: selection.interfaceNumber,
                inputEndpoint: selection.inputEndpoint,
                outputEndpoint: selection.outputEndpoint
            )
            let session = try await DirectUSBMuxSession.open(
                over: pipe,
                outboundUSBPacketSize:
                    selection.outputMaximumPacketSize
            )
            return WebUSBDeviceConnection(
                productName: productName,
                serialNumber: serialNumber,
                transport: DirectUSBMuxTransport(session: session)
            )
        } catch {
            await closeAfterFailedConnection()
            throw error
        }
    }

    /// Selects the direct-usbmux configuration after opening or resetting the
    /// device.
    ///
    /// WebUSB resets can clear `USBDevice.configuration`, so claim recovery
    /// must restore the expected configuration before retrying the interface.
    private func selectConfigurationIfNeeded(
        _ configurationValue: UInt8
    ) async throws {
        let currentConfiguration = device.configuration.object
        let currentValue = currentConfiguration?
            .configurationValue.number
            .flatMap(UInt8.init(exactly:))
        guard currentValue != configurationValue else {
            return
        }
        try await perform(
            "selectConfiguration",
            arguments: [configurationValue]
        )
    }

    /// Converts browser USB descriptors into the transport's portable model.
    private func configurationDescriptors() throws
        -> [USBConfigurationDescriptor]
    {
        let configurations = try webUSBArray(
            device.configurations,
            field: "USBDevice.configurations"
        )
        return try configurations.map { value in
            guard let configuration = value.object else {
                throw WebUSBError.invalidBrowserResponse(
                    "A USB configuration is not an object."
                )
            }
            let interfaces = try webUSBArray(
                configuration.interfaces,
                field: "USBConfiguration.interfaces"
            )
            return USBConfigurationDescriptor(
                value: try webUSBUInt8(
                    configuration.configurationValue,
                    field: "USBConfiguration.configurationValue"
                ),
                interfaces: try interfaces.map(interfaceDescriptor)
            )
        }
    }

    /// Converts one browser interface and all advertised alternates.
    private func interfaceDescriptor(
        _ value: JSValue
    ) throws -> USBInterfaceDescriptor {
        guard let interface = value.object else {
            throw WebUSBError.invalidBrowserResponse(
                "A USB interface is not an object."
            )
        }
        let alternates = try webUSBArray(
            interface.alternates,
            field: "USBInterface.alternates"
        )
        return USBInterfaceDescriptor(
            number: try webUSBUInt8(
                interface.interfaceNumber,
                field: "USBInterface.interfaceNumber"
            ),
            alternates: try alternates.map(alternateDescriptor)
        )
    }

    /// Converts one alternate descriptor and its endpoint list.
    private func alternateDescriptor(
        _ value: JSValue
    ) throws -> USBAlternateDescriptor {
        guard let alternate = value.object else {
            throw WebUSBError.invalidBrowserResponse(
                "A USB alternate is not an object."
            )
        }
        let endpoints = try webUSBArray(
            alternate.endpoints,
            field: "USBAlternateInterface.endpoints"
        )
        return USBAlternateDescriptor(
            setting: try webUSBUInt8(
                alternate.alternateSetting,
                field: "USBAlternateInterface.alternateSetting"
            ),
            classCode: try webUSBUInt8(
                alternate.interfaceClass,
                field: "USBAlternateInterface.interfaceClass"
            ),
            subclassCode: try webUSBUInt8(
                alternate.interfaceSubclass,
                field: "USBAlternateInterface.interfaceSubclass"
            ),
            protocolCode: try webUSBUInt8(
                alternate.interfaceProtocol,
                field: "USBAlternateInterface.interfaceProtocol"
            ),
            endpoints: try endpoints.map(endpointDescriptor)
        )
    }

    /// Converts one browser endpoint descriptor.
    private func endpointDescriptor(
        _ value: JSValue
    ) throws -> USBEndpointDescriptor {
        guard let endpoint = value.object else {
            throw WebUSBError.invalidBrowserResponse(
                "A USB endpoint is not an object."
            )
        }
        guard
            let direction = USBEndpointDirection(
                webUSBValue: endpoint.direction
            )
        else {
            throw WebUSBError.invalidBrowserResponse(
                "USBEndpoint.direction is not in or out."
            )
        }
        guard
            let transferType = USBTransferType(
                webUSBValue: endpoint.type
            )
        else {
            throw WebUSBError.invalidBrowserResponse(
                "USBEndpoint.type is not a recognized transfer type."
            )
        }
        let maximumPacketSize = try webUSBCount(
            endpoint.packetSize,
            field: "USBEndpoint.packetSize"
        )
        guard maximumPacketSize > 0 else {
            throw WebUSBError.invalidBrowserResponse(
                "USBEndpoint.packetSize must be positive."
            )
        }
        return USBEndpointDescriptor(
            number: try webUSBUInt8(
                endpoint.endpointNumber,
                field: "USBEndpoint.endpointNumber"
            ),
            direction: direction,
            transferType: transferType,
            maximumPacketSize: maximumPacketSize
        )
    }

    /// Invokes and awaits one promise-returning method on the USB device.
    private func perform(
        _ name: String,
        arguments: [any ConvertibleToJSValue] = []
    ) async throws {
        _ = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                name,
                on: device,
                arguments: arguments
            ),
            operation: name
        )
    }

    /// Best-effort cleanup when interface setup or mux negotiation fails.
    private func closeAfterFailedConnection() async {
        guard device.opened.boolean == true else {
            return
        }
        _ = try? await awaitJavaScriptPromise(
            try invokeJavaScriptMethod("close", on: device),
            operation: "close"
        )
    }
}

/// Connected WebUSB transport for pairing and device-service sessions.
///
/// JavaScript values remain inside the browser adapter. This sendable wrapper
/// retains only the actor-backed direct-usbmux transport, so higher-level
/// `RorkDevice` operations can run without exposing JavaScriptKit types.
public final class WebUSBDeviceConnection: Sendable {
    /// Product name captured before leaving the JavaScript actor.
    public let productName: String?

    /// Serial number captured before leaving the JavaScript actor.
    public let serialNumber: String?

    /// Multiplexed transport shared by pairing and authenticated sessions.
    private let transport: DirectUSBMuxTransport

    /// Creates a connected browser device around a negotiated mux session.
    init(
        productName: String?,
        serialNumber: String?,
        transport: DirectUSBMuxTransport
    ) {
        self.productName = productName
        self.serialNumber = serialNumber
        self.transport = transport
    }

    /// Establishes Lockdown trust and returns the record the caller must save.
    ///
    /// One candidate host identity is generated and reused while the device
    /// waits for the user to approve its Trust dialog. The browser application
    /// owns persistence because Web storage policy belongs to the embedding
    /// product rather than this transport package.
    ///
    /// - Parameters:
    ///   - hostIdentifier: Stable identifier for this browser application
    ///     installation. Persist it alongside pairing records and reuse it
    ///     when pairing every device.
    ///   - trustTimeout: Maximum time to wait for the device-side decision.
    ///   - retryInterval: Delay between checks while confirmation is pending.
    ///   - onProgress: Optional callback for user-facing pairing state.
    /// - Returns: Accepted pairing record containing the device escrow bag.
    /// - Throws: Browser transport, cryptography, Lockdown, user-decision, or
    ///   timeout errors encountered while establishing trust.
    public func pair(
        using hostIdentifier: WebUSBHostIdentifier,
        trustTimeout: Duration = .seconds(120),
        retryInterval: Duration = .seconds(1),
        onProgress: (@Sendable (DevicePairingProgress) -> Void)? = nil
    ) async throws -> PairingRecord {
        let client = DeviceClient()
        let information = try await client.pairingInformation(
            using: transport
        )
        let candidate = try await WebPairingMaterial.candidate(
            for: information,
            systemBUID: hostIdentifier.rawValue
        )
        return try await client.pair(
            using: candidate,
            over: transport,
            trustTimeout: trustTimeout,
            retryInterval: retryInterval,
            onProgress: onProgress
        )
    }

    /// Opens an authenticated Lockdown session using a saved pairing record.
    ///
    /// The returned `DeviceSession` exposes transport-neutral AFC,
    /// InstallationProxy, provisioning-profile, and installed-app operations.
    ///
    /// - Parameters:
    ///   - pairingRecord: Record previously accepted by this physical device.
    ///   - label: Diagnostic client label sent in Lockdown requests.
    /// - Returns: Authenticated session for device services and app management.
    /// - Throws: Browser transport, Lockdown, pairing, or secure-session errors.
    public func openSession(
        using pairingRecord: PairingRecord,
        label: String = "rorkdevice.web"
    ) async throws -> DeviceSession {
        try await DeviceClient().connect(
            using: transport,
            pairingRecord: pairingRecord,
            label: label
        )
    }

    /// Revokes the supplied host identity on the connected device.
    ///
    /// The caller should remove its persisted record only after this method
    /// succeeds.
    ///
    /// - Throws: Browser transport or Lockdown errors while revoking trust.
    public func unpair(using pairingRecord: PairingRecord) async throws {
        try await DeviceClient().unpair(
            using: pairingRecord,
            over: transport
        )
    }

    /// Releases the claimed browser interface and all service connections.
    public func close() async {
        await transport.close()
    }
}

extension USBEndpointDirection {
    /// Converts the WebUSB direction string into a portable descriptor value.
    fileprivate init?(webUSBValue: JSValue) {
        switch webUSBValue.string {
        case "in":
            self = .input
        case "out":
            self = .output
        default:
            return nil
        }
    }
}

extension USBTransferType {
    /// Converts the WebUSB endpoint type string into a portable descriptor value.
    fileprivate init?(webUSBValue: JSValue) {
        switch webUSBValue.string {
        case "bulk":
            self = .bulk
        case "interrupt":
            self = .interrupt
        case "isochronous":
            self = .isochronous
        case "control":
            self = .control
        default:
            return nil
        }
    }
}
#endif
