#if canImport(JavaScriptKit)
import Foundation
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
        throw WebUSBError.browserOperationFailed(
            operation: name,
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
        throw WebUSBError.browserOperationFailed(
            operation: operation,
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
