import Foundation
import NIOCore
import NIOSSL

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
