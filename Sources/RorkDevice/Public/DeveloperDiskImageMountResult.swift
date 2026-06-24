/// Outcome of mounting an iOS 17+ personalized Developer Disk Image.
///
/// The cases preserve the relationship between mount status and ticket origin:
/// an already-mounted image has no ticket source, while a new mount always
/// records the source of its personalization ticket.
public enum DeveloperDiskImageMountResult: Equatable, Sendable {
    /// Whether the image was mounted by this operation or was already present.
    public enum Status: String, Codable, Sendable {
        /// The operation uploaded and mounted the image.
        case mounted

        /// The device already had a personalized image mounted.
        case alreadyMounted
    }

    /// Origin of the personalization ticket used for a new mount.
    public enum TicketSource: String, Codable, Sendable {
        /// The device reused a previously issued personalization manifest.
        case deviceManifest

        /// Apple TSS issued a new personalization ticket.
        case appleTSS
    }

    /// The device already had a personalized image mounted.
    case alreadyMounted

    /// The operation uploaded and mounted the image with the supplied ticket.
    ///
    /// - Parameter ticketSource: Origin of the personalization ticket accepted
    ///   by the device.
    case mounted(ticketSource: TicketSource)

    /// Final mount status.
    public var status: Status {
        switch self {
        case .alreadyMounted:
            return .alreadyMounted
        case .mounted:
            return .mounted
        }
    }

    /// Ticket origin, or `nil` when the image was already mounted.
    public var ticketSource: TicketSource? {
        switch self {
        case .alreadyMounted:
            return nil
        case let .mounted(ticketSource):
            return ticketSource
        }
    }

    /// Whether an existing CoreDevice tunnel must be recreated.
    ///
    /// Remote Service Discovery captures its service list when the tunnel
    /// opens. A newly mounted image adds developer services, so callers must
    /// create a fresh tunnel before trying to use those services.
    public var requiresTunnelRestart: Bool {
        status == .mounted
    }
}
