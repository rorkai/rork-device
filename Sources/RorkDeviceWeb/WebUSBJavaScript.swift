import Foundation

/// Converts browser diagnostics into stable transport failures.
///
/// Chromium does not expose a structured error code for several WebUSB
/// lifecycle failures. Keeping the exact message matching at this boundary
/// prevents browser-specific text from leaking into clients.
func webUSBError(
    for operation: String,
    message: String
) -> WebUSBError {
    let normalizedOperation = operation.lowercased()
    let normalizedMessage = message.lowercased()

    if normalizedMessage.contains("device was disconnected")
        || (normalizedOperation == "open"
            && normalizedMessage.contains("notfounderror"))
        || (normalizedOperation == "reset"
            && normalizedMessage.contains("unable to reset the device"))
    {
        return .deviceUnavailable
    }

    if normalizedOperation == "claiminterface"
        && normalizedMessage.contains("unable to claim interface")
    {
        return .interfaceInUse
    }

    return .browserOperationFailed(
        operation: operation,
        message: message
    )
}

#if canImport(JavaScriptKit)
import JavaScriptEventLoop
import JavaScriptKit

/// Invokes one JavaScript method while preserving synchronous exceptions.
@MainActor
func invokeJavaScriptMethod(
    _ name: String,
    on object: JSObject,
    arguments: [any ConvertibleToJSValue] = []
) throws -> JSValue {
    guard let method = object[name].function else {
        throw WebUSBError.invalidBrowserResponse(
            "The \(name) method is unavailable."
        )
    }
    do {
        return try method.throws(
            this: object,
            arguments: arguments
        )
    } catch let error as JSException {
        throw webUSBError(
            for: name,
            message: error.description
        )
    }
}

/// Waits for a JavaScript promise without moving its value off-actor.
@MainActor
func awaitJavaScriptPromise(
    _ value: JSValue,
    operation: String
) async throws -> JSValue {
    guard let object = value.object,
        let promise = JSPromise(object)
    else {
        throw WebUSBError.invalidBrowserResponse(
            "\(operation) did not return a Promise."
        )
    }
    do {
        return try await promise.value()
    } catch {
        throw webUSBError(
            for: operation,
            message: error.description
        )
    }
}

/// Copies a JavaScript `ArrayBuffer` into Swift-owned storage.
@MainActor
func dataFromJavaScriptArrayBuffer(
    _ value: JSValue,
    field: String
) throws -> Data {
    guard let buffer = value.object else {
        throw WebUSBError.invalidBrowserResponse(
            "\(field) is not an ArrayBuffer."
        )
    }
    let typedArray = JSObject.global.Uint8Array.function!.new(buffer)
    return Data.construct(
        from: JSTypedArray<UInt8>(
            unsafelyWrapping: typedArray
        )
    )
}

/// Reads an unsigned byte-sized integer from a JavaScript descriptor.
@MainActor
func webUSBUInt8(
    _ value: JSValue,
    field: String
) throws -> UInt8 {
    guard let number = value.number,
        number.isFinite,
        number.rounded() == number,
        number >= 0,
        number <= Double(UInt8.max)
    else {
        throw WebUSBError.invalidBrowserResponse(
            "\(field) is not an unsigned 8-bit integer."
        )
    }
    return UInt8(number)
}

/// Reads a nonnegative platform integer from a JavaScript response.
@MainActor
func webUSBCount(
    _ value: JSValue,
    field: String
) throws -> Int {
    guard let number = value.number,
        number.isFinite,
        number.rounded() == number,
        number >= 0,
        number <= Double(Int.max)
    else {
        throw WebUSBError.invalidBrowserResponse(
            "\(field) is not a nonnegative integer."
        )
    }
    return Int(number)
}

/// Reads a required JavaScript array from a WebUSB descriptor.
@MainActor
func webUSBArray(
    _ value: JSValue,
    field: String
) throws -> JSArray {
    guard let array = value.array else {
        throw WebUSBError.invalidBrowserResponse(
            "\(field) is not an array."
        )
    }
    return array
}
#endif
