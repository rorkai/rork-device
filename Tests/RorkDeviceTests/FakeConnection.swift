import Foundation
@testable import RorkDevice

final class FakeConnection: DeviceConnection {
    private(set) var sent: [Data] = []
    private var inbound: Data

    /// Simulates a connection loss after a protocol request has been sent.
    private let receiveFailureAfterSendCount: Int?
    private let receiveFailure: RorkDeviceError
    private(set) var isClosed = false

    init(
        inbound: Data = Data(),
        receiveFailureAfterSendCount: Int? = nil,
        receiveFailure: RorkDeviceError = .transport(
            "Injected receive failure."
        )
    ) {
        self.inbound = inbound
        self.receiveFailureAfterSendCount = receiveFailureAfterSendCount
        self.receiveFailure = receiveFailure
    }

    func enqueue(_ data: Data) {
        inbound.append(data)
    }

    func send(_ data: Data) async throws {
        guard !isClosed else {
            throw RorkDeviceError.transport("Fake connection is closed.")
        }
        sent.append(data)
    }

    func receive(exactly count: Int) async throws -> Data {
        guard !isClosed else {
            throw RorkDeviceError.transport("Fake connection is closed.")
        }
        if let receiveFailureAfterSendCount,
           sent.count >= receiveFailureAfterSendCount {
            throw receiveFailure
        }
        guard inbound.count >= count else {
            throw RorkDeviceError.transport("Fake connection underflow.")
        }
        let prefix = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(prefix)
    }

    func close() {
        isClosed = true
    }
}
