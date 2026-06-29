/// Closes a WebUSB device without skipping later cleanup after one step fails.
///
/// A physical disconnect can invalidate any browser operation in this
/// sequence. The remaining steps must still run because reset is what returns
/// an attached iPhone to the host's USB stack, while close releases the
/// browser's device handle.
@MainActor
func closeWebUSBDevice(
    releaseInterface: () async throws -> Void,
    resetDevice: () async throws -> Void,
    closeDevice: () async throws -> Void
) async {
    _ = try? await releaseInterface()
    _ = try? await resetDevice()
    _ = try? await closeDevice()
}

/// Setup milestone reached before a WebUSB connection attempt failed.
enum WebUSBConnectionSetupProgress: Equatable {
    /// The browser device has been opened, but no interface is claimed.
    case opened

    /// The direct-usbmux interface is claimed and must be returned to the host.
    case claimedInterface(UInt8)
}

/// Minimal browser USB operations needed for failure cleanup.
@MainActor
protocol WebUSBConnectionHandle: AnyObject {
    /// Releases a previously claimed USB interface.
    func releaseInterface(_ interfaceNumber: UInt8) async throws

    /// Resets the browser-owned USB device.
    func reset() async throws

    /// Closes the browser-owned USB device handle.
    func close() async throws
}

/// Cleans up a failed WebUSB connection attempt with the least disruptive
/// browser operations available for the point where setup failed.
///
/// Once the direct-usbmux interface has been claimed, reset is required to
/// make iOS and the host USB stack re-enumerate the device before the next
/// browser connection attempt. Before the claim succeeds, closing the handle is
/// enough and avoids resetting a device whose interface was never taken.
@MainActor
extension WebUSBConnectionHandle {
    func cleanUpFailedConnection(
        at progress: WebUSBConnectionSetupProgress
    ) async {
        switch progress {
        case .opened:
            _ = try? await close()

        case .claimedInterface(let interfaceNumber):
            await closeWebUSBDevice(
                releaseInterface: {
                    try await self.releaseInterface(interfaceNumber)
                },
                resetDevice: {
                    try await self.reset()
                },
                closeDevice: {
                    try await self.close()
                }
            )
        }
    }
}

#if canImport(JavaScriptKit)
import Foundation
import JavaScriptFoundationCompat
import JavaScriptKit

/// Claimed WebUSB bulk interface used by the direct-usbmux session.
///
/// JavaScript objects remain main-actor confined for their complete lifetime.
/// The async protocol requirements let the mux actor hop to the JavaScript
/// executor for each transfer without treating browser handles as sendable.
@MainActor
final class WebUSBPipe: DirectUSBMuxIO {
    /// Browser-owned `USBDevice`.
    private let device: JSObject

    /// Interface released when the pipe closes.
    private let interfaceNumber: UInt8

    /// Device-to-host bulk endpoint.
    private let inputEndpoint: UInt8

    /// Host-to-device bulk endpoint.
    private let outputEndpoint: UInt8

    /// Prevents transfers and duplicate cleanup after closure.
    private var isClosed = false

    /// Creates a pipe after its configuration, interface, and alternate have
    /// already been selected.
    init(
        device: JSObject,
        interfaceNumber: UInt8,
        inputEndpoint: UInt8,
        outputEndpoint: UInt8
    ) {
        self.device = device
        self.interfaceNumber = interfaceNumber
        self.inputEndpoint = inputEndpoint
        self.outputEndpoint = outputEndpoint
    }

    /// Reads one WebUSB bulk transfer.
    func read(upTo byteCount: Int) async throws -> Data {
        guard !isClosed else {
            throw WebUSBError.connectionClosed
        }
        guard byteCount > 0 else {
            throw WebUSBError.invalidBrowserResponse(
                "A transferIn request must have positive capacity."
            )
        }

        let value = try await awaitJavaScriptMethod(
            "transferIn",
            on: device,
            arguments: [
                inputEndpoint,
                byteCount,
            ],
            describedAs: "Reading from USB"
        )
        guard let result = value.object else {
            throw WebUSBError.invalidBrowserResponse(
                "transferIn did not resolve to a result object."
            )
        }
        try validateTransferStatus(
            result,
            operation: "USB read"
        )
        guard let dataView = result.data.object,
            let buffer = dataView.buffer.object
        else {
            throw WebUSBError.invalidBrowserResponse(
                "transferIn returned no DataView."
            )
        }

        let byteOffset = try webUSBCount(
            dataView.byteOffset,
            field: "DataView.byteOffset"
        )
        let byteLength = try webUSBCount(
            dataView.byteLength,
            field: "DataView.byteLength"
        )
        let typedArray = JSObject.global.Uint8Array.function!.new(
            buffer,
            byteOffset,
            byteLength
        )
        return Data.construct(
            from: JSTypedArray<UInt8>(
                unsafelyWrapping: typedArray
            )
        )
    }

    /// Writes one complete WebUSB bulk transfer.
    func write(_ data: Data) async throws {
        guard !isClosed else {
            throw WebUSBError.connectionClosed
        }
        guard !data.isEmpty else {
            return
        }

        try await writeTransfer(data)
    }

    /// Writes one browser transfer and validates complete delivery.
    private func writeTransfer(_ data: Data) async throws {
        let value = try await awaitJavaScriptMethod(
            "transferOut",
            on: device,
            arguments: [
                outputEndpoint,
                data.jsTypedArray,
            ],
            describedAs: "Writing to USB"
        )
        guard let result = value.object else {
            throw WebUSBError.invalidBrowserResponse(
                "transferOut did not resolve to a result object."
            )
        }
        try validateTransferStatus(
            result,
            operation: "USB write"
        )
        let writtenByteCount = try webUSBCount(
            result.bytesWritten,
            field: "USBOutTransferResult.bytesWritten"
        )
        guard writtenByteCount == data.count else {
            throw WebUSBError.incompleteWrite(
                expectedByteCount: data.count,
                actualByteCount: writtenByteCount
            )
        }
    }

    /// Releases the claimed interface and returns the device to the host.
    ///
    /// Chromium can leave an iPhone absent from the host's usbmux service after
    /// direct interface access ends. Resetting after release forces the host to
    /// re-enumerate the device so native clients can discover it again.
    func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        guard device.opened.boolean == true else {
            return
        }

        await closeWebUSBDevice(
            releaseInterface: {
                _ = try await awaitJavaScriptMethod(
                    "releaseInterface",
                    on: device,
                    arguments: [interfaceNumber],
                    describedAs: "Releasing the USB interface"
                )
            },
            resetDevice: {
                _ = try await awaitJavaScriptMethod(
                    "reset",
                    on: device,
                    describedAs: "Resetting the USB device"
                )
            },
            closeDevice: {
                _ = try await awaitJavaScriptMethod(
                    "close",
                    on: device,
                    describedAs: "Closing the USB device"
                )
            }
        )
    }

    /// Requires WebUSB's transfer status to be `ok`.
    private func validateTransferStatus(
        _ result: JSObject,
        operation: String
    ) throws {
        guard let status = result.status.string else {
            throw WebUSBError.invalidBrowserResponse(
                "\(operation) returned no status."
            )
        }
        guard status == "ok" else {
            throw WebUSBError.transferFailed(
                operation: operation,
                status: status
            )
        }
    }
}
#endif
