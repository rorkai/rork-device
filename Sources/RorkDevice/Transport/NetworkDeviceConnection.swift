#if canImport(Network) && canImport(Security)
import Dispatch
import Foundation
import Network
import OSLog
import Security

/// TLS 1.2 PSK byte stream implemented with Apple's Network framework.
///
/// Remote pairing requires cipher suites and interface binding exposed by
/// Network.framework but not by the package's general SwiftNIO TCP transport.
/// The type remains internal because callers interact with it through
/// `RemotePairingTunnel`.
final class NetworkDeviceConnection: DeviceConnection {
    /// Unified logger for remote-pairing transport diagnostics.
    private static let logger = Logger(
        subsystem: "dev.rork.rork-device",
        category: "remote-pairing"
    )

    /// Framework connection that owns the socket and TLS state.
    private let connection: NWConnection

    /// Serial queue used for state transitions and timeout delivery.
    private let queue: DispatchQueue

    /// Wraps a configured connection before it is started.
    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens a TLS 1.2 PSK connection, optionally constrained to one interface.
    static func connect(
        to host: String,
        port: UInt16,
        preSharedKey: Data,
        through interface: NWInterface? = nil,
        timeout: Duration
    ) async throws -> NetworkDeviceConnection {
        guard !preSharedKey.isEmpty else {
            throw RorkDeviceError.invalidInput("TLS pre-shared key is empty.")
        }

        return try await connect(
            to: host,
            port: port,
            parameters: makeTLSParameters(
                preSharedKey: preSharedKey,
                through: interface
            ),
            timeout: timeout
        )
    }

    /// Builds the exact TLS and interface policy required by remote pairing.
    static func makeTLSParameters(
        preSharedKey: Data,
        through interface: NWInterface?
    ) -> NWParameters {
        let parameters = NWParameters(
            tls: makeTLSOptions(preSharedKey: preSharedKey),
            tcp: NWProtocolTCP.Options()
        )
        parameters.requiredInterface = interface
        return parameters
    }

    /// Starts a Network.framework connection using already configured parameters.
    private static func connect(
        to host: String,
        port: UInt16,
        parameters: NWParameters,
        timeout: Duration
    ) async throws -> NetworkDeviceConnection {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        let queue = DispatchQueue(label: "dev.rork.rork-device.network.\(UUID().uuidString)")
        let wrapper = NetworkDeviceConnection(connection: connection, queue: queue)
        try await wrapper.start(timeout: timeout)
        return wrapper
    }

    /// Sends all bytes and reports completion after Network.framework processes them.
    func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RorkDeviceError.transport(
                        "Network send failed: \(error.localizedDescription)"
                    ))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receives exactly the requested number of bytes or fails on early closure.
    func receive(exactly byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput("Cannot receive a negative byte count.")
        }
        guard byteCount > 0 else {
            return Data()
        }

        var received = Data()
        while received.count < byteCount {
            received.append(try await receive(upTo: byteCount - received.count))
        }
        return received
    }

    /// Cancels the framework connection. Repeated calls are harmless.
    func close() {
        connection.cancel()
    }

    /// Waits for the ready state while enforcing cancellation and a connect timeout.
    private func start(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = NetworkConnectionStartWaiter(continuation: continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.logNegotiatedTLSCipherSuite()
                        waiter.resume(with: .success(()))
                    case let .failed(error):
                        waiter.resume(with: .failure(RorkDeviceError.transport(
                            "TLS connection failed: \(error.localizedDescription)"
                        )))
                    case .cancelled:
                        waiter.resume(with: .failure(RorkDeviceError.transport(
                            "TLS connection was cancelled."
                        )))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.dispatchTimeInterval) { [connection] in
                    if waiter.resume(with: .failure(RorkDeviceError.transport(
                        "TLS connection timed out."
                    ))) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Records the cipher suite selected by the device after TLS completes.
    ///
    /// Network.framework exposes negotiated TLS state only after the connection
    /// becomes ready. Missing metadata is logged separately because it indicates
    /// a diagnostic failure rather than an unsuccessful handshake.
    private func logNegotiatedTLSCipherSuite() {
        guard let metadata = connection.metadata(
            definition: NWProtocolTLS.definition
        ) as? NWProtocolTLS.Metadata else {
            Self.logger.notice(
                "Remote-pairing TLS negotiated cipher metadata is unavailable."
            )
            return
        }

        let cipherSuite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(
            metadata.securityProtocolMetadata
        )
        let description = remotePairingTLSCipherSuiteDescription(
            rawValue: cipherSuite.rawValue
        )
        Self.logger.info(
            "Remote-pairing TLS negotiated cipher: \(description, privacy: .public)"
        )
    }

    /// Receives one nonempty chunk no larger than the requested byte count.
    private func receive(upTo byteCount: Int) async throws -> Data {
        while true {
            let result = await withCheckedContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: byteCount
                ) { content, _, isComplete, error in
                    continuation.resume(returning: NetworkReceiveResult(
                        content: content,
                        isComplete: isComplete,
                        error: error
                    ))
                }
            }
            if let error = result.error {
                throw RorkDeviceError.transport(
                    "Network receive failed: \(error.localizedDescription)"
                )
            }
            if let content = result.content, !content.isEmpty {
                return content
            }
            if result.isComplete {
                throw RorkDeviceError.transport("Network connection closed.")
            }
        }
    }
}

/// Returns a stable IANA cipher-suite name and hexadecimal code for diagnostics.
///
/// The switch covers every suite currently offered by the remote-pairing
/// transport. Unknown values retain their wire code so logs remain actionable
/// if Apple selects a suite added by a future configuration change.
func remotePairingTLSCipherSuiteDescription(rawValue: UInt16) -> String {
    let name = switch rawValue {
    case 0x00AF:
        "TLS_PSK_WITH_AES_256_CBC_SHA384"
    case 0x00AE:
        "TLS_PSK_WITH_AES_128_CBC_SHA256"
    case 0x008D:
        "TLS_PSK_WITH_AES_256_CBC_SHA"
    case 0x008C:
        "TLS_PSK_WITH_AES_128_CBC_SHA"
    default:
        "unknown TLS cipher suite"
    }
    return "\(name) (\(String(format: "0x%04X", rawValue)))"
}

/// Snapshot returned by one asynchronous Network.framework receive callback.
private struct NetworkReceiveResult {
    /// Bytes delivered by the callback, if any.
    let content: Data?

    /// Whether the peer completed its outbound stream.
    let isComplete: Bool

    /// Framework error associated with the receive operation.
    let error: NWError?
}

/// Resumes a connection-start continuation at most once across racing outcomes.
private final class NetworkConnectionStartWaiter: @unchecked Sendable {
    /// Protects continuation ownership across the state and timeout queues.
    private let lock = NSLock()

    /// Pending continuation, cleared by the first terminal outcome.
    private var continuation: CheckedContinuation<Void, Error>?

    /// Stores the continuation until the connection becomes ready or fails.
    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    /// Resumes the waiter if no competing outcome has already won.
    @discardableResult
    func resume(with result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

/// Configures TLS 1.2 PSK and the cipher suites accepted by remote pairing.
private func makeTLSOptions(preSharedKey: Data) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let securityOptions = options.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv12)
    sec_protocol_options_add_pre_shared_key(
        securityOptions,
        dispatchData(preSharedKey),
        dispatchData(Data())
    )
    for rawValue: UInt16 in [0x00AF, 0x00AE, 0x008D, 0x008C] {
        sec_protocol_options_append_tls_ciphersuite(
            securityOptions,
            tls_ciphersuite_t(rawValue: rawValue)!
        )
    }
    return options
}

/// Bridges Foundation `Data` to the dispatch representation required by Security.
private func dispatchData(_ data: Data) -> dispatch_data_t {
    let value = data.withUnsafeBytes { bytes in
        DispatchData(bytes: bytes)
    }
    return value as AnyObject as! dispatch_data_t
}

private extension Duration {
    /// Converts a positive Swift duration to a bounded dispatch interval.
    var dispatchTimeInterval: DispatchTimeInterval {
        let parts = components
        let seconds = Double(parts.seconds)
        let attoseconds = Double(parts.attoseconds)
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(max(1, min(nanoseconds, Double(Int.max)))))
    }
}
#endif
