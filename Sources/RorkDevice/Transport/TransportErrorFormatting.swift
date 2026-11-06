import Foundation
import NIOCore
import NIOSSL

#if canImport(NIOPosix) && !os(WASI)
import NIOPosix
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Formats low-level transport errors for package-level diagnostics.
///
/// Transport implementations may receive either package errors or framework
/// errors from SwiftNIO and platform APIs. This helper keeps those diagnostics
/// consistent across TCP, Unix-domain, and future connection backends.
/// Windows diagnostics omit POSIX errno because Winsock uses a separate error
/// domain.
func describeTransportError(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    if let ioError = error as? NIOCore.IOError {
        #if os(Windows)
        return "SwiftNIO IOError: \(ioError.description)"
        #else
        return "SwiftNIO IOError errno=\(ioError.errnoCode): \(ioError.description)"
        #endif
    }
    if let sslError = error as? NIOSSLError {
        return String(reflecting: sslError)
    }
    return error.localizedDescription
}

/// Reports whether a bind failed because the requested address is already in use.
///
/// Windows inspects the Winsock error code. Other hosts compare the POSIX errno.
func isAddressInUseError(_ error: NIOCore.IOError) -> Bool {
    #if os(Windows)
    error.winsockErrorCode == WSAEADDRINUSE
    #else
    return error.errnoCode == EADDRINUSE
    #endif
}

/// Reports whether the peer reset the connection.
func isConnectionResetError(_ error: NIOCore.IOError) -> Bool {
    #if os(Windows)
    error.winsockErrorCode == WSAECONNRESET
    #else
    return error.errnoCode == ECONNRESET
    #endif
}

/// Reports whether the operating system timed the operation out.
func isTimedOutError(_ error: NIOCore.IOError) -> Bool {
    #if os(Windows)
    error.winsockErrorCode == WSAETIMEDOUT
    #else
    return error.errnoCode == ETIMEDOUT
    #endif
}

/// A socket failure supervisors act on, recognized by error code rather
/// than localized text.
enum SocketFailure: Equatable {
    case reset
    case timedOut
}

/// Recognizes a reset or timeout, including the forms SwiftNIO's connect
/// reports them in.
func socketFailure(of error: Error) -> SocketFailure? {
    if let ioError = error as? NIOCore.IOError {
        if isConnectionResetError(ioError) {
            return .reset
        }
        if isTimedOutError(ioError) {
            return .timedOut
        }
        return nil
    }
    if let channelError = error as? ChannelError, case .connectTimeout = channelError {
        return .timedOut
    }
    #if canImport(NIOPosix) && !os(WASI)
    if let connectionError = error as? NIOConnectionError {
        return socketFailure(ofAttempts: connectionError.connectionErrors.map(\.error))
    }
    #endif
    return nil
}

/// Recognizes a connect that tried several resolved addresses.
///
/// The failure has one kind only when every attempt failed the same way;
/// a mix, such as one refused and one timed out, stays a plain transport
/// failure.
func socketFailure(ofAttempts errors: [Error]) -> SocketFailure? {
    guard let first = errors.first.map(socketFailure(of:)) else {
        return nil
    }
    return errors.dropFirst().allSatisfy { socketFailure(of: $0) == first } ? first : nil
}

/// Converts a framework transport failure into the package error surface,
/// typing the socket failures supervisors act on.
///
/// - Parameter context: Names the failed step, prefixed to the diagnostic.
func transportError(from error: Error, context: String? = nil) -> RorkDeviceError {
    let detail = describeTransportError(error)
    let message = context.map { "\($0): \(detail)" } ?? detail
    switch socketFailure(of: error) {
    case .reset:
        return .connectionReset(message)
    case .timedOut:
        return .timedOut(message)
    case nil:
        return .transport(message)
    }
}
