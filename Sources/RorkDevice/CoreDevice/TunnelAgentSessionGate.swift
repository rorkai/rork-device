import Foundation

/// Hands the current tunnel cycle's shared device session to IPC handlers.
///
/// The serving loop dispatches every request as its own task while the
/// reconnect loop replaces the session across tunnel cycles. This gate is
/// their synchronized meeting point. Cycles publish a session when they become
/// ready and withdraw it when the tunnel drops. Handlers wait for a session
/// with bounded patience, so a request that arrives between cycles rides out
/// a quick reconnect and fails with the last reported loss failure instead of
/// a bare timeout when the tunnel stays down.
///
/// The unchecked conformance is safe because every stored property is guarded
/// by the lock. The sessions handed out are RSD-backed, whose backend holds
/// only immutable routing state and opens an independent connection per
/// service request, so concurrent handlers never share a live connection.
public final class TunnelAgentSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var session: DeviceSession?
    private var lastLossFailure: RorkDeviceFailure?
    private var waiters: [UUID: CheckedContinuation<DeviceSession?, Never>] = [:]

    /// Creates a gate with no session, which stays closed until the first
    /// tunnel cycle publishes one.
    public init() {}

    /// Publishes the session serving the tunnel cycle that just became ready.
    public func publish(_ session: DeviceSession) {
        let resumed: [CheckedContinuation<DeviceSession?, Never>] = lock.withLock {
            self.session = session
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in resumed {
            waiter.resume(returning: session)
        }
    }

    /// Withdraws the current session because its tunnel cycle ended.
    ///
    /// Waiters keep waiting for the next cycle. A nil failure keeps the last
    /// known one, so a teardown path that cannot name its cause never erases
    /// a failure the reconnect loop reported.
    public func markLost(failure: RorkDeviceFailure?) {
        lock.withLock {
            session = nil
            if let failure {
                lastLossFailure = failure
            }
        }
    }

    /// Returns the current session, waiting for the next cycle's when the
    /// tunnel is down.
    ///
    /// - Parameter patience: How long a request may wait for the tunnel to
    ///   come back before failing.
    /// - Throws: `CancellationError` when the waiting task is cancelled, or
    ///   `RorkDeviceError.tunnelUnavailable` carrying the last known loss
    ///   failure on timeout.
    public func waitForSession(upTo patience: Duration) async throws -> DeviceSession {
        let id = UUID()
        let timeout = Task {
            try await Task.sleep(for: patience)
            resume(id, with: nil)
        }
        defer {
            timeout.cancel()
        }

        let provided: DeviceSession? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The session check and waiter registration share one
                // critical section, so a publish cannot slip between them.
                // A task already cancelled on entry had its `onCancel` run
                // before this closure, which found no waiter to expire, so
                // the cancellation check must repeat inside the lock.
                enum Claim {
                    case session(DeviceSession)
                    case cancelled
                    case registered
                }
                let claim: Claim = lock.withLock {
                    if let session {
                        return .session(session)
                    }
                    if Task.isCancelled {
                        return .cancelled
                    }
                    waiters[id] = continuation
                    return .registered
                }
                switch claim {
                case .session(let session):
                    continuation.resume(returning: session)
                case .cancelled:
                    continuation.resume(returning: nil)
                case .registered:
                    break
                }
            }
        } onCancel: {
            resume(id, with: nil)
        }

        if let provided {
            return provided
        }
        try Task.checkCancellation()
        throw RorkDeviceError.tunnelUnavailable(
            lastFailure: lock.withLock { lastLossFailure }
        )
    }

    /// Resumes one registered waiter exactly once, whoever gets there first.
    private func resume(_ id: UUID, with session: DeviceSession?) {
        let waiter = lock.withLock {
            waiters.removeValue(forKey: id)
        }
        waiter?.resume(returning: session)
    }

}
