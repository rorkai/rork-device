import Foundation
import NIOCore
import NIOSSL

/// Formats low-level transport errors for package-level diagnostics.
///
/// Transport implementations may receive either package errors or framework
/// errors from SwiftNIO and platform APIs. This helper keeps those diagnostics
/// consistent across TCP, Unix-domain, and future connection backends.
func describeTransportError(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    if let ioError = error as? NIOCore.IOError {
        return "SwiftNIO IOError errno=\(ioError.errnoCode): \(ioError.description)"
    }
    if let sslError = error as? NIOSSLError {
        return String(reflecting: sslError)
    }
    return error.localizedDescription
}
