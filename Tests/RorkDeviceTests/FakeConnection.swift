import Foundation
@testable import RorkDevice

final class FakeConnection: DeviceConnection, @unchecked Sendable {
    /// Protects all mutable state; tests may pump reads and writes from
    /// independent tasks, as the userspace-network packet pumps do.
    private let lock = NSLock()

    private var sentData: [Data] = []
    private var inbound: Data

    /// Simulates a connection loss after a protocol request has been sent.
    private let receiveFailureAfterSendCount: Int?
    private let receiveFailure: RorkDeviceError

    /// Whether a drained inbound buffer suspends the reader until closure
    /// instead of failing with an underflow.
    private let blocksWhenDrained: Bool

    /// Readers suspended on an empty inbound buffer while blocking is enabled.
    private var drainedWaiters: [CheckedContinuation<Void, Error>] = []

    private var closed = false

    var sent: [Data] {
        lock.withLock { sentData }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    init(
        inbound: Data = Data(),
        receiveFailureAfterSendCount: Int? = nil,
        receiveFailure: RorkDeviceError = .transport(
            "Injected receive failure."
        ),
        blocksWhenDrained: Bool = false
    ) {
        self.inbound = inbound
        self.receiveFailureAfterSendCount = receiveFailureAfterSendCount
        self.receiveFailure = receiveFailure
        self.blocksWhenDrained = blocksWhenDrained
    }

    func enqueue(_ data: Data) {
        lock.withLock {
            inbound.append(data)
        }
    }

    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !closed else {
                throw RorkDeviceError.transport("Fake connection is closed.")
            }
            sentData.append(data)
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        while true {
            enum ReadOutcome {
                case data(Data)
                case underflow
                case waitUntilClosed
            }
            let outcome: ReadOutcome = try lock.withLock {
                guard !closed else {
                    throw RorkDeviceError.transport(
                        "Fake connection is closed."
                    )
                }
                if let receiveFailureAfterSendCount,
                   sentData.count >= receiveFailureAfterSendCount {
                    throw receiveFailure
                }
                if inbound.count >= count {
                    let prefix = inbound.prefix(count)
                    inbound.removeFirst(count)
                    return .data(Data(prefix))
                }
                return blocksWhenDrained ? .waitUntilClosed : .underflow
            }

            switch outcome {
            case let .data(data):
                return data
            case .underflow:
                throw RorkDeviceError.transport("Fake connection underflow.")
            case .waitUntilClosed:
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let closedWhileRegistering: Bool = lock.withLock {
                        guard !closed else {
                            return true
                        }
                        drainedWaiters.append(continuation)
                        return false
                    }
                    if closedWhileRegistering {
                        continuation.resume(
                            throwing: RorkDeviceError.transport(
                                "Fake connection is closed."
                            )
                        )
                    }
                }
            }
        }
    }

    func close() {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            closed = true
            let waiters = drainedWaiters
            drainedWaiters.removeAll()
            return waiters
        }
        waiters.forEach {
            $0.resume(
                throwing: RorkDeviceError.transport(
                    "Fake connection is closed."
                )
            )
        }
    }
}
