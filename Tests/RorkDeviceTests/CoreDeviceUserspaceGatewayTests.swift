import Foundation
import XCTest

@testable import RorkDevice

final class CoreDeviceUserspaceGatewayTests: XCTestCase {
    func testForwardsFragmentedPreambleAndPayloadInBothDirections() async throws {
        let deviceConnection = GatewayTestConnection(
            response: Data("world".utf8)
        )
        let requestedPorts = RequestedPortRecorder()
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0
        ) { port in
            await requestedPorts.append(port)
            return deviceConnection
        }
        defer {
            gateway.close()
        }

        let client = try await TCPDeviceConnection.connect(
            to: gateway.host,
            port: gateway.port,
            timeout: .seconds(2)
        )
        defer {
            client.close()
        }

        var request = try ipv6AddressBytes(
            "fd00::1",
            invalidMessage: "Invalid test device address."
        )
        request.appendLittleEndian(UInt32(54_130))
        request.append(Data("hello".utf8))

        try await client.send(Data(request.prefix(7)))
        try await Task.sleep(for: .milliseconds(10))
        try await client.send(Data(request.dropFirst(7)))

        let response = try await client.receive(exactly: 5)
        let ports = await requestedPorts.values
        let sentData = await deviceConnection.sentData

        XCTAssertEqual(response, Data("world".utf8))
        XCTAssertEqual(ports, [54_130])
        XCTAssertEqual(sentData, Data("hello".utf8))
    }

    func testBindingAnOccupiedPortThrowsPortUnavailable() async throws {
        let first = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0
        ) { _ in
            GatewayTestConnection(response: Data())
        }
        defer {
            first.close()
        }

        do {
            let second = try await CoreDeviceUserspaceGateway.start(
                deviceAddress: "fd00::1",
                host: "127.0.0.1",
                port: first.port
            ) { _ in
                GatewayTestConnection(response: Data())
            }
            second.close()
            XCTFail("Expected binding an occupied port to fail")
        } catch let error as CoreDeviceUserspaceGateway.PortUnavailableError {
            XCTAssertEqual(error.port, first.port)
            XCTAssertEqual(
                String(describing: error),
                "Local gateway port \(first.port) on 127.0.0.1 is already in use."
            )
        }
    }

    func testRejectsPreambleForAnotherDeviceAddress() async throws {
        let requestedPorts = RequestedPortRecorder()
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0
        ) { port in
            await requestedPorts.append(port)
            return GatewayTestConnection(response: Data())
        }
        defer {
            gateway.close()
        }

        let client = try await TCPDeviceConnection.connect(
            to: gateway.host,
            port: gateway.port,
            timeout: .seconds(2)
        )
        defer {
            client.close()
        }
        var request = try ipv6AddressBytes(
            "fd00::2",
            invalidMessage: "Invalid test device address."
        )
        request.appendLittleEndian(UInt32(54_130))
        try await client.send(request)

        await XCTAssertThrowsErrorAsync({
            _ = try await client.receive(exactly: 1)
        }) { _ in }
        let ports = await requestedPorts.values
        XCTAssertEqual(ports, [])
    }

    func testClosingGatewayTerminatesActiveForwardingConnection() async throws {
        let connectionOpened = expectation(
            description: "Gateway opened the device-side connection."
        )
        let deviceConnection = GatewayTestConnection(response: Data())
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0
        ) { _ in
            connectionOpened.fulfill()
            return deviceConnection
        }

        let client = try await TCPDeviceConnection.connect(
            to: gateway.host,
            port: gateway.port,
            timeout: .seconds(2)
        )
        var request = try ipv6AddressBytes(
            "fd00::1",
            invalidMessage: "Invalid test device address."
        )
        request.appendLittleEndian(UInt32(54_130))
        try await client.send(request)
        await fulfillment(of: [connectionOpened], timeout: 1)

        let gatewayClosed = expectation(
            description: "Gateway accept loop stopped."
        )
        let waitTask = Task {
            defer {
                gatewayClosed.fulfill()
            }
            try await gateway.waitUntilClosed()
        }

        gateway.close()
        await fulfillment(of: [gatewayClosed], timeout: 1)
        waitTask.cancel()
        client.close()
    }

    func testWaitUntilClosedCompletesNormallyAfterExplicitClose() async throws {
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0
        ) { _ in
            GatewayTestConnection(response: Data())
        }
        let waitTask = Task {
            try await gateway.waitUntilClosed()
        }

        await Task.yield()
        gateway.close()

        try await waitTask.value
    }

    func testExplicitCloseDoesNotSurfaceNetworkMonitorCancellation() async throws {
        let monitorStarted = expectation(
            description: "The network monitor started waiting."
        )
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0,
            waitUntilNetworkCloses: {
                monitorStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        ) { _ in
            GatewayTestConnection(response: Data())
        }
        defer {
            gateway.close()
        }
        await fulfillment(of: [monitorStarted], timeout: 1)
        let waitTask = Task {
            try await gateway.waitUntilClosed()
        }

        gateway.close()

        try await waitTask.value
    }

    func testWaitUntilClosedThrowsWhenUserspaceNetworkFails() async throws {
        let networkError = RorkDeviceError.transport(
            "CoreDevice packet pump stopped."
        )
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0,
            waitUntilNetworkCloses: {
                throw networkError
            }
        ) { _ in
            GatewayTestConnection(response: Data())
        }
        defer {
            gateway.close()
        }

        do {
            try await gateway.waitUntilClosed()
            XCTFail("Expected the gateway to surface the network failure.")
        } catch {
            XCTAssertEqual(error as? RorkDeviceError, networkError)
        }
    }

    func testWaitUntilClosedCompletesNormallyWhenUserspaceNetworkCloses() async throws {
        let gateway = try await CoreDeviceUserspaceGateway.start(
            deviceAddress: "fd00::1",
            host: "127.0.0.1",
            port: 0,
            waitUntilNetworkCloses: {}
        ) { _ in
            GatewayTestConnection(response: Data())
        }
        defer {
            gateway.close()
        }

        try await gateway.waitUntilClosed()
    }
}

private actor RequestedPortRecorder {
    private var ports: [UInt16] = []

    var values: [UInt16] {
        ports
    }

    func append(_ port: UInt16) {
        ports.append(port)
    }
}

private final class GatewayTestConnection:
    DeviceConnection,
    StreamingDeviceConnection,
    @unchecked Sendable
{
    private let state: GatewayTestConnectionState

    var sentData: Data {
        get async {
            await state.sentData
        }
    }

    init(response: Data) {
        state = GatewayTestConnectionState(response: response)
    }

    func send(_ data: Data) async throws {
        await state.send(data)
    }

    func receive(exactly byteCount: Int) async throws -> Data {
        var result = Data()
        while result.count < byteCount {
            result.append(
                try await receive(upTo: byteCount - result.count)
            )
        }
        return result
    }

    func receive(upTo byteCount: Int) async throws -> Data {
        try await state.receive(upTo: byteCount)
    }

    func close() {
        Task {
            await state.close()
        }
    }
}

private actor GatewayTestConnectionState {
    private var sent = Data()
    private var inbound: Data
    private var isClosed = false
    private var waiter: CheckedContinuation<Data, Error>?

    var sentData: Data {
        sent
    }

    init(response: Data) {
        inbound = response
    }

    func send(_ data: Data) {
        sent.append(data)
        resumeWaiterIfPossible()
    }

    func receive(upTo byteCount: Int) async throws -> Data {
        guard byteCount > 0 else {
            return Data()
        }
        if !inbound.isEmpty {
            return consume(byteCount)
        }
        if isClosed {
            throw RorkDeviceError.transport(
                "Gateway test connection is closed."
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        waiter?.resume(
            throwing: RorkDeviceError.transport(
                "Gateway test connection is closed."
            )
        )
        waiter = nil
    }

    private func resumeWaiterIfPossible() {
        guard let waiter, !inbound.isEmpty else {
            return
        }
        self.waiter = nil
        waiter.resume(returning: consume(inbound.count))
    }

    private func consume(_ maximumCount: Int) -> Data {
        let count = min(maximumCount, inbound.count)
        let data = Data(inbound.prefix(count))
        inbound.removeFirst(count)
        return data
    }
}
