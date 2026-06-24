import Foundation

/// Converts browser diagnostics into stable transport failures.
///
/// Chromium does not expose a structured error code for several WebUSB
/// lifecycle failures. The JavaScript method name remains the stable
/// classification key, while an optional description can make unclassified
/// errors readable without affecting recovery behavior.
func webUSBError(
    forMethod method: String,
    describedAs operation: String? = nil,
    message: String
) -> WebUSBError {
    let normalizedMethod = method.lowercased()
    let normalizedMessage = message.lowercased()

    if normalizedMessage.contains("device was disconnected")
        || (normalizedMethod == "open"
            && normalizedMessage.contains("notfounderror"))
        || (normalizedMethod == "reset"
            && normalizedMessage.contains("unable to reset the device"))
    {
        return .deviceUnavailable
    }

    if normalizedMethod == "claiminterface"
        && normalizedMessage.contains("unable to claim interface")
    {
        return .interfaceInUse
    }

    return .browserOperationFailed(
        operation: operation ?? method,
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
            forMethod: name,
            message: error.description
        )
    }
}

/// Invokes a promise-returning JavaScript method and awaits its result.
///
/// The method name remains the stable classifier key. `operation` is used only
/// when presenting a failure that has no typed WebUSB classification.
@MainActor
func awaitJavaScriptMethod(
    _ name: String,
    on object: JSObject,
    arguments: [any ConvertibleToJSValue] = [],
    describedAs operation: String? = nil
) async throws -> JSValue {
    let operationDescription = operation ?? name
    let value = try invokeJavaScriptMethod(
        name,
        on: object,
        arguments: arguments
    )
    guard let object = value.object,
        let promise = JSPromise(object)
    else {
        throw WebUSBError.invalidBrowserResponse(
            "\(operationDescription) did not return a Promise."
        )
    }
    do {
        return try await promise.value()
    } catch {
        throw webUSBError(
            forMethod: name,
            describedAs: operationDescription,
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
