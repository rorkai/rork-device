import Foundation
@testable import RorkDevice

final class FakeConnection: DeviceConnection {
    private(set) var sent: [Data] = []
    private var inbound: Data
    private var isClosed = false

    init(inbound: Data = Data()) {
        self.inbound = inbound
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

    func receive(count: Int) async throws -> Data {
        guard !isClosed else {
            throw RorkDeviceError.transport("Fake connection is closed.")
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
