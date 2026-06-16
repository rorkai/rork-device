import Foundation

/// Arguments and environment supplied when CoreDevice launches an application.
///
/// The options map directly to CoreDevice's app-service request. They are
/// transport-independent, but launching requires a `DeviceSession` created
/// from Remote Service Discovery because Lockdown does not expose this service.
public struct ApplicationLaunchOptions: Equatable, Sendable {
    /// Command-line arguments passed to the application process.
    public let arguments: [String]

    /// Environment variables added to the launched process.
    public let environment: [String: String]

    /// Whether CoreDevice should terminate an existing instance before launch.
    public let terminateExistingProcess: Bool

    /// Creates application launch options.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments passed to the process.
    ///   - environment: Environment variables added to the process.
    ///   - terminateExistingProcess: Whether an existing process for the same
    ///     application should be terminated before launch.
    public init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateExistingProcess: Bool = false
    ) {
        self.arguments = arguments
        self.environment = environment
        self.terminateExistingProcess = terminateExistingProcess
    }
}
