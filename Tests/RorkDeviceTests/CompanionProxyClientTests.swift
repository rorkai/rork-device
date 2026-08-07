import Foundation
@testable import RorkDevice
import XCTest

final class CompanionProxyClientTests: XCTestCase {
    /// Protects the command and response fields required by device registry
    /// discovery.
    func testPairedDeviceIdentifiersUsesRegistryCommand() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-2", "WATCH-1"],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let identifiers = try await client.pairedDeviceIdentifiers()

        XCTAssertEqual(identifiers, ["WATCH-2", "WATCH-1"])
        let request = try await capturedRequest(from: connection)
        XCTAssertEqual(request["Command"] as? String, "GetDeviceRegistry")
    }

    /// Protects the asymmetric field names required for registry value
    /// requests.
    func testValueUsesRegistryLookupKeys() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [
                    "DeviceName": "My Watch",
                ],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let value = try await client.value(
            forKey: "DeviceName",
            on: "WATCH-1"
        )

        XCTAssertEqual(value as? String, "My Watch")
        let request = try await capturedRequest(from: connection)
        XCTAssertEqual(
            request["Command"] as? String,
            "GetValueFromRegistry"
        )
        XCTAssertEqual(
            request["GetValueGizmoUDIDKey"] as? String,
            "WATCH-1"
        )
        XCTAssertEqual(
            request["GetValueKeyKey"] as? String,
            "DeviceName"
        )
    }

    /// Treats an omitted key as optional metadata because registry contents
    /// vary by device and OS version.
    func testValueReturnsNilWhenRegistryOmitsKey() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "RetrievedValueDictionary": [:],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let value = try await client.value(
            forKey: "ModelNumber",
            on: "WATCH-1"
        )

        XCTAssertNil(value)
    }

    /// Normalizes the service's sentinel response into an empty collection.
    func testPairedDeviceIdentifiersReturnsEmptyForNoPairedWatches() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": "NoPairedWatches",
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let identifiers = try await client.pairedDeviceIdentifiers()

        XCTAssertEqual(identifiers, [])
    }

    /// Keeps unsupported optional metadata from aborting device discovery.
    func testValueReturnsNilForUnsupportedRegistryKey() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": "UnsupportedWatchKey",
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        let value = try await client.value(
            forKey: "ModelNumber",
            on: "WATCH-1"
        )

        XCTAssertNil(value)
    }

    /// Rejects mixed registry arrays before invalid identifiers reach callers.
    func testPairedDeviceIdentifiersRejectsMalformedRegistry() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-1", 42],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        do {
            _ = try await client.pairedDeviceIdentifiers()
            XCTFail("Expected malformed registry rejection.")
        } catch let error as RorkDeviceError {
            guard case .protocolViolation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// Rejects malformed error fields even when the response also contains
    /// otherwise valid registry data.
    func testPairedDeviceIdentifiersRejectsNonStringError() async throws {
        let connection = FakeConnection(
            inbound: try PropertyListMessageFramer.encode([
                "Error": 1,
                "PairedDevicesArray": ["WATCH-1"],
            ])
        )
        let client = CompanionProxyClient(connection: connection)

        do {
            _ = try await client.pairedDeviceIdentifiers()
            XCTFail("Expected malformed error rejection.")
        } catch let error as RorkDeviceError {
            XCTAssertEqual(
                error,
                .protocolViolation(
                    "Companion proxy response contains a non-string Error field."
                )
            )
        }
    }

    /// Keeps concurrent callers from interleaving requests on one ordered
    /// service stream.
    func testSerializesConcurrentRequests() async throws {
        var inbound = Data()
        inbound.append(
            try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-1"],
            ])
        )
        inbound.append(
            try PropertyListMessageFramer.encode([
                "PairedDevicesArray": ["WATCH-2"],
            ])
        )
        let firstRequestSent = expectation(
            description: "The first request reached the connection."
        )
        let connection = ExchangeCheckingConnection(
            inbound: inbound,
            firstRequestSent: firstRequestSent
        )
        let client = CompanionProxyClient(connection: connection)

        async let first = client.pairedDeviceIdentifiers()
        await fulfillment(of: [firstRequestSent], timeout: 1)
        async let second = client.pairedDeviceIdentifiers()
        try await Task.sleep(for: .milliseconds(20))
        await connection.releaseFirstReceive()

        let identifiers = try await (first, second)

        XCTAssertEqual(identifiers.0, ["WATCH-1"])
        XCTAssertEqual(identifiers.1, ["WATCH-2"])
    }
}

/// Connection that rejects a second send until the current response is read.
private final class ExchangeCheckingConnection:
    DeviceConnection,
    @unchecked Sendable
{
    /// Protects the scripted transport state used by concurrent child tasks.
    private let lock = NSLock()

    /// Response frames returned in request order.
    private var inbound: Data

    /// Number of exact reads made across all response frames.
    private var receiveCount = 0

    /// Whether a sent request still owns the next response frame.
    private var exchangeIsActive = false

    /// Whether the connection has been closed.
    private var isClosed = false

    /// Gate that holds the first response read while the second call starts.
    private let firstReceiveGate = TestAsyncGate()

    /// XCTest signal fulfilled after the first request is sent.
    private let firstRequestSent: XCTestExpectation

    /// Creates a connection with two scripted response frames.
    init(
        inbound: Data,
        firstRequestSent: XCTestExpectation
    ) {
        self.inbound = inbound
        self.firstRequestSent = firstRequestSent
    }

    /// Rejects a send that arrives before the prior response is consumed.
    func send(_: Data) async throws {
        let isFirstRequest = try lock.withLock {
            guard !isClosed else {
                throw RorkDeviceError.transport(
                    "Exchange-checking connection is closed."
                )
            }
            guard !exchangeIsActive else {
                throw RorkDeviceError.transport(
                    "Companion proxy requests interleaved."
                )
            }
            exchangeIsActive = true
            return receiveCount == 0
        }
        if isFirstRequest {
            firstRequestSent.fulfill()
        }
    }

    /// Returns framed response bytes after the first read gate opens.
    func receive(exactly byteCount: Int) async throws -> Data {
        let shouldWait = lock.withLock {
            receiveCount += 1
            return receiveCount == 1
        }
        if shouldWait {
            await firstReceiveGate.wait()
        }

        return try lock.withLock {
            guard inbound.count >= byteCount else {
                throw RorkDeviceError.transport(
                    "Exchange-checking connection underflow."
                )
            }
            let bytes = Data(inbound.prefix(byteCount))
            inbound.removeFirst(byteCount)
            if receiveCount.isMultiple(of: 2) {
                exchangeIsActive = false
            }
            return bytes
        }
    }

    /// Opens the first response read after both callers have started.
    func releaseFirstReceive() async {
        await firstReceiveGate.open()
    }

    /// Marks the scripted connection as closed.
    func close() {
        lock.withLock {
            isClosed = true
        }
    }
}

/// One-shot asynchronous gate used to hold the first scripted response.
private actor TestAsyncGate {
    /// Whether future waiters may continue immediately.
    private var isOpen = false

    /// Tasks waiting for the gate to open.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until the gate has opened.
    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    /// Opens the gate and resumes every waiting task.
    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

/// Decodes one captured request through the production framing implementation.
private func capturedRequest(
    from connection: FakeConnection
) async throws -> [String: Any] {
    let data = try XCTUnwrap(connection.sent.first)
    return try await PropertyListMessageFramer.receive(
        from: FakeConnection(inbound: data)
    )
}
