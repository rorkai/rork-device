/// Outcome of mounting an iOS 17+ personalized Developer Disk Image.
public struct DeveloperDiskImageMountResult:
    Codable,
    Equatable,
    Sendable
{
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
        case device

        /// Apple TSS issued a new personalization ticket.
        case appleTSS
    }

    /// Final mount status.
    public let status: Status

    /// Ticket origin, or `nil` when the image was already mounted.
    public let ticketSource: TicketSource?

    /// Whether an existing CoreDevice tunnel must be recreated.
    ///
    /// Remote Service Discovery captures its service list when the tunnel
    /// opens. A newly mounted image adds developer services, so callers must
    /// create a fresh tunnel before trying to use those services.
    public var requiresTunnelRestart: Bool {
        status == .mounted
    }

    /// Creates a mount result.
    ///
    /// - Parameters:
    ///   - status: Whether this operation performed the mount.
    ///   - ticketSource: Ticket origin for a new mount.
    public init(status: Status, ticketSource: TicketSource?) {
        self.status = status
        self.ticketSource = ticketSource
    }
}
