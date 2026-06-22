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

        let value = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "transferIn",
                on: device,
                arguments: [
                    inputEndpoint,
                    byteCount,
                ]
            ),
            operation: "Reading from USB"
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
        let value = try await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "transferOut",
                on: device,
                arguments: [
                    outputEndpoint,
                    data.jsTypedArray,
                ]
            ),
            operation: "Writing to USB"
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

    /// Releases the claimed interface and closes the browser device.
    func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        guard device.opened.boolean == true else {
            return
        }

        _ = try? await awaitJavaScriptPromise(
            try invokeJavaScriptMethod(
                "releaseInterface",
                on: device,
                arguments: [interfaceNumber]
            ),
            operation: "Releasing the USB interface"
        )
        _ = try? await awaitJavaScriptPromise(
            try invokeJavaScriptMethod("close", on: device),
            operation: "Closing the USB device"
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
