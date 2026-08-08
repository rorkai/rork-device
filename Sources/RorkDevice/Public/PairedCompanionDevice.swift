/// Identity information reported for a device paired through an iPhone.
public struct PairedCompanionDevice: Codable, Equatable, Sendable {
    /// Unique companion-device identifier.
    public let udid: String

    /// Human-readable device name when present in the registry.
    public let name: String?

    /// Hardware model number when present in the registry.
    public let modelNumber: String?

    /// Creates paired companion-device information.
    ///
    /// - Parameters:
    ///   - udid: Unique companion-device identifier.
    ///   - name: Optional human-readable device name.
    ///   - modelNumber: Optional hardware model number.
    public init(
        udid: String,
        name: String? = nil,
        modelNumber: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.modelNumber = modelNumber
    }
}
