import Foundation

/// Client for the device's AMFI Lockdown service.
///
/// The service controls the Developer Mode setup flow introduced in iOS 16.
/// This client currently exposes only the non-destructive reveal operation,
/// which makes the Developer Mode setting visible without enabling it,
/// restarting the device, or confirming the post-restart prompt.
final class DeveloperModeClient {
    /// Connected `com.apple.amfi.lockdown` service stream.
    private let connection: DeviceConnection

    /// Creates a client over an already-started AMFI service connection.
    ///
    /// The caller retains ownership of the connection and is responsible for
    /// closing it after the operation completes.
    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Makes the Developer Mode setting visible on the connected device.
    ///
    /// iOS reports device-side failures in an `Error` field and successful
    /// requests with a `success` field. A response containing neither is
    /// rejected because it does not establish whether the setting was revealed.
    func reveal() async throws {
        try await PropertyListMessageFramer.send(
            ["action": 0],
            to: connection
        )
        let response = try await PropertyListMessageFramer.receive(
            from: connection
        )

        if let message = response.string("Error") {
            throw RorkDeviceError.lockdown(
                "Developer Mode reveal failed: \(message)"
            )
        }
        guard response.bool("success") == true else {
            throw RorkDeviceError.protocolViolation(
                "Developer Mode reveal response did not report success."
            )
        }
    }
}
