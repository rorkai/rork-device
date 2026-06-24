import Foundation
import RorkDevice

#if canImport(JavaScriptKit)
import JavaScriptKit
#endif

/// Stable identifier for one browser application's pairing identity.
///
/// Create this value once, persist it in browser storage, and reuse it for
/// every device paired by the same application installation. Pairing records
/// bind this identifier into Lockdown session requests; replacing it later can
/// make previously accepted records unusable.
public struct WebUSBHostIdentifier:
    Codable,
    Equatable,
    Hashable,
    RawRepresentable,
    Sendable
{
    /// Persisted nonempty identifier supplied to Lockdown.
    public let rawValue: String

    /// Generates a new identifier for a browser application installation.
    ///
    /// Persist the result before pairing a device. Repeatedly creating this
    /// value for the same installation defeats its stable-identity contract.
    public init() {
        rawValue = UUID().uuidString.uppercased()
    }

    /// Restores a previously persisted browser host identifier.
    ///
    /// - Parameter rawValue: Stored identifier. Surrounding whitespace is
    ///   removed before validation.
    public init?(rawValue: String) {
        let rawValue = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !rawValue.isEmpty else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates one persisted identifier.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identifier = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A WebUSB host identifier cannot be empty."
            )
        }
        self = identifier
    }

    /// Encodes the identifier as its portable string representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Failures produced by the browser WebUSB transport.
public enum WebUSBError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    /// The current JavaScript environment cannot provide WebUSB.
    case unavailable

    /// Device selection or another browser operation was rejected.
    case browserOperationFailed(operation: String, message: String)

    /// The selected device is no longer available through its browser handle.
    ///
    /// WebUSB handles represent one physical attachment. Reconnects and USB
    /// ownership changes require the caller to obtain a current handle.
    /// `WebUSB.requestDevice()` is the reliable recovery path when the browser
    /// continues returning an invalidated authorized-device object.
    case deviceUnavailable

    /// Another application currently owns the device's direct USB interface.
    ///
    /// WebUSB cannot share a claimed interface with a native device service.
    /// The owning application must release the device before retrying.
    case interfaceInUse

    /// The selected device does not expose Apple's direct-usbmux interface.
    case directUSBMuxInterfaceUnavailable

    /// The browser returned a value that does not match the WebUSB contract.
    case invalidBrowserResponse(String)

    /// A USB transfer completed with a non-success status.
    case transferFailed(operation: String, status: String)

    /// WebUSB reported fewer bytes written than the supplied packet.
    case incompleteWrite(expectedByteCount: Int, actualByteCount: Int)

    /// An operation used a browser device connection after it closed.
    case connectionClosed

    /// Human-readable description suitable for diagnostics and product UI.
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "WebUSB is not available in this browser environment."
        case .browserOperationFailed(let operation, let message):
            return "\(operation) failed: \(message)"
        case .deviceUnavailable:
            return "The selected Apple device is no longer available. Reconnect it, close other device-management apps, and try again."
        case .interfaceInUse:
            return "The selected Apple device is in use by another application. Close the other application and try again."
        case .directUSBMuxInterfaceUnavailable:
            return "The selected device does not expose a compatible direct USB interface."
        case .invalidBrowserResponse(let message):
            return "The browser returned an invalid WebUSB response: \(message)"
        case .transferFailed(let operation, let status):
            return "\(operation) completed with USB status \(status)."
        case .incompleteWrite(let expectedByteCount, let actualByteCount):
            return "WebUSB wrote \(actualByteCount) of \(expectedByteCount) bytes."
        case .connectionClosed:
            return "The WebUSB device connection is closed."
        }
    }
}

/// Entry point for requesting Apple devices through the browser.
public enum WebUSB {
    #if canImport(JavaScriptKit)
    /// Whether the current JavaScript environment exposes `navigator.usb`.
    @MainActor
    public static var isSupported: Bool {
        JSObject.global.navigator.object?.usb.object != nil
    }

    /// Returns connected Apple devices already authorized for this origin.
    ///
    /// This method does not show a permission prompt and does not open or claim
    /// any device. Browser authorization is distinct from Lockdown trust: a
    /// returned device can still require `WebUSBDeviceConnection.pair(using:)`
    /// before authenticated services are available.
    ///
    /// Browser authorization does not guarantee that a returned handle remains
    /// usable after another application temporarily owns USB. If `connect()`
    /// reports `WebUSBError.deviceUnavailable`, obtain a new handle through
    /// `requestDevice()` from a subsequent user activation.
    ///
    /// - Returns: Attached Apple devices previously granted to this origin.
    /// - Throws: `WebUSBError.unavailable`, a browser operation failure, or a
    ///   malformed-response error.
    @MainActor
    public static func authorizedDevices() async throws -> [WebUSBDevice] {
        guard let usb = JSObject.global.navigator.object?.usb.object else {
            throw WebUSBError.unavailable
        }

        let result = try await awaitJavaScriptMethod(
            "getDevices",
            on: usb,
            describedAs: "Listing authorized USB devices"
        )
        let devices = try webUSBArray(
            result,
            field: "navigator.usb.getDevices result"
        )
        return try devices.compactMap { value in
            guard let device = value.object else {
                throw WebUSBError.invalidBrowserResponse(
                    "An authorized USB device is not an object."
                )
            }
            let vendorIdentifier = try webUSBCount(
                device.vendorId,
                field: "USBDevice.vendorId"
            )
            guard vendorIdentifier == 0x05AC else {
                return nil
            }
            return WebUSBDevice(device)
        }
    }

    /// Prompts the user to grant access to an attached Apple USB device.
    ///
    /// Browsers require this method to run from a user activation such as a
    /// button click. The returned device is not opened or claimed until
    /// `WebUSBDevice.connect()` is called.
    ///
    /// - Returns: User-selected Apple device.
    /// - Throws: `WebUSBError.unavailable`, a browser rejection when the picker
    ///   is cancelled or denied, or a malformed-response error.
    @MainActor
    public static func requestDevice() async throws -> WebUSBDevice {
        guard let usb = JSObject.global.navigator.object?.usb.object else {
            throw WebUSBError.unavailable
        }

        let filter = JSObject()
        filter["vendorId"] = .number(0x05AC)
        let options = JSObject()
        options["filters"] = .object(
            JSObject.global.Array.function!.new(filter)
        )
        let selected = try await awaitJavaScriptMethod(
            "requestDevice",
            on: usb,
            arguments: [options],
            describedAs: "Requesting a USB device"
        )
        guard let device = selected.object else {
            throw WebUSBError.invalidBrowserResponse(
                "requestDevice did not resolve to a USBDevice object."
            )
        }
        return WebUSBDevice(device)
    }
    #else
    /// Native builds expose the package for tests but cannot access WebUSB.
    @MainActor
    public static var isSupported: Bool {
        false
    }
    #endif
}
