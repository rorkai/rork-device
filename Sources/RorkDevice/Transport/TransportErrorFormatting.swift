import Foundation

/// Formats low-level transport errors for package-level diagnostics.
///
/// Transport implementations may receive either package errors or framework
/// errors from SwiftNIO and platform APIs. This helper keeps those diagnostics
/// consistent across TCP, Unix-domain, and future connection backends.
func describeTransportError(_ error: Error) -> String {
    if let deviceError = error as? RorkDeviceError {
        return deviceError.description
    }
    return error.localizedDescription
}

