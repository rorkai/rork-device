import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS

/// TLS-protected connection layered over an arbitrary streaming transport.
///
/// Native SwiftNIO transports insert TLS directly into their channel pipeline.
/// Other transports, including direct WebUSB streams, have no NIO channel to
/// modify. This adapter runs the same NIO SSL handler in an embedded channel,
/// then exchanges the resulting ciphertext through the supplied connection.
final class InMemoryTLSDeviceConnection:
    StreamingDeviceConnection,
    Sendable
{
    /// Maximum encrypted chunk requested from the underlying byte stream.
    private static let encryptedReadCapacity = 16 * 1_024

    /// Plain byte stream that carries TLS records.
    private let connection: any StreamingDeviceConnection

    /// Serializes writes produced by application traffic and TLS control frames.
    private let writer: InMemoryTLSWriter

    /// Owns the embedded NIO channel and decrypted receive buffer.
    private let state: InMemoryTLSState

    /// Retains a fully negotiated TLS stream.
    private init(
        connection: any StreamingDeviceConnection,
        writer: InMemoryTLSWriter,
        state: InMemoryTLSState
    ) {
        self.connection = connection
        self.writer = writer
        self.state = state
    }

    /// Negotiates TLS over a transport-provided byte stream.
    ///
    /// The same certificate context and exact device-certificate pin used by
    /// native channels are applied here. The method does not return until the
    /// TLS handshake has completed.
    static func establish(
        over connection: any StreamingDeviceConnection,
        configuration: NIOSecureSessionConfiguration
    ) async throws -> InMemoryTLSDeviceConnection {
        let state = try await InMemoryTLSState(
            configuration: configuration
        )
        let writer = InMemoryTLSWriter(connection: connection)
        let secureConnection = InMemoryTLSDeviceConnection(
            connection: connection,
            writer: writer,
            state: state
        )

        let initialFlight = try await state.takeOutboundData()
        try await writer.send(initialFlight)
        while true {
            switch await state.handshakeResult {
            case .pending:
                let encrypted = try await connection.receive(
                    upTo: encryptedReadCapacity
                )
                try await writer.send(
                    try await state.receiveEncryptedData(encrypted)
                )

            case .succeeded:
                return secureConnection

            case .failed(let description):
                if let verificationFailure =
                    await state.certificateVerificationFailure
                {
                    throw RorkDeviceError.secureSession(
                        verificationFailure
                    )
                }
                throw RorkDeviceError.secureSession(
                    "TLS handshake failed: \(description)"
                )
            }
        }
    }

    /// Encrypts and sends one complete application buffer.
    func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try await writer.send(
            try await state.sendPlaintext(data)
        )
    }

    /// Receives exactly the requested number of decrypted bytes.
    func receive(exactly byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput(
                "Cannot receive a negative byte count."
            )
        }
        var result = Data(capacity: byteCount)
        while result.count < byteCount {
            result.append(
                try await receive(upTo: byteCount - result.count)
            )
        }
        return result
    }

    /// Receives available decrypted bytes up to the requested capacity.
    func receive(upTo byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput(
                "Cannot receive a negative byte count."
            )
        }
        guard byteCount > 0 else {
            return Data()
        }

        while true {
            let plaintext = await state.takePlaintext(upTo: byteCount)
            if !plaintext.isEmpty {
                return plaintext
            }

            let encrypted = try await connection.receive(
                upTo: Self.encryptedReadCapacity
            )
            try await writer.send(
                try await state.receiveEncryptedData(encrypted)
            )
        }
    }

    /// Closes the TLS pipeline and its underlying transport.
    func close() {
        connection.close()
        Task {
            await state.close()
        }
    }
}

/// Serializes ciphertext writes emitted by independent TLS operations.
private actor InMemoryTLSWriter {
    /// Underlying full-duplex transport.
    private let connection: any StreamingDeviceConnection

    /// Creates a writer for one secure stream.
    init(connection: any StreamingDeviceConnection) {
        self.connection = connection
    }

    /// Sends each nonempty TLS record in production order.
    func send(_ chunks: [Data]) async throws {
        for chunk in chunks where !chunk.isEmpty {
            try await connection.send(chunk)
        }
    }
}

/// Mutable NIO SSL state isolated from concurrent connection operations.
private actor InMemoryTLSState {
    /// Thread-safe in-memory channel that transforms plaintext and TLS records.
    #if canImport(Dispatch)
    private let channel: NIOAsyncTestingChannel
    #else
    /// Single-threaded in-memory channel used when Dispatch is unavailable.
    ///
    /// WASI executes this actor on one thread, satisfying `EmbeddedChannel`'s
    /// thread-confinement requirement without unsafe isolation annotations.
    private let channel: EmbeddedChannel
    #endif

    /// Tracks handshake completion and terminal TLS errors.
    private let handshakeObserver: InMemoryTLSHandshakeObserver

    /// Records exact device-certificate verification failures.
    private let certificatePin: DeviceCertificatePin

    /// Decrypted bytes not yet consumed by a caller.
    private var plaintextBuffer = Data()

    /// Creates and activates a TLS client pipeline.
    init(configuration: NIOSecureSessionConfiguration) async throws {
        let certificatePin = DeviceCertificatePin(
            expectedCertificate: configuration.trustedServerCertificate
        )
        let handshakeObserver = InMemoryTLSHandshakeObserver()
        let address = try SocketAddress(
            ipAddress: "127.0.0.1",
            port: 0
        )

        #if canImport(Dispatch)
        let channel = try await NIOAsyncTestingChannel { channel in
            let tlsHandler = try NIOSSLClientHandler(
                context: configuration.context,
                serverHostname: nil,
                customVerificationCallback: certificatePin.verify
            )
            try channel.pipeline.syncOperations.addHandlers([
                tlsHandler,
                handshakeObserver,
            ])
        }
        channel.connect(to: address, promise: nil)
        await channel.testingEventLoop.run()
        try await channel.throwIfErrorCaught()
        #else
        let tlsHandler = try NIOSSLClientHandler(
            context: configuration.context,
            serverHostname: nil,
            customVerificationCallback: certificatePin.verify
        )
        let channel = EmbeddedChannel(
            handlers: [
                tlsHandler,
                handshakeObserver,
            ]
        )
        try await activateEmbeddedTLSChannel(
            channel,
            connectingTo: address
        )
        #endif

        self.channel = channel
        self.certificatePin = certificatePin
        self.handshakeObserver = handshakeObserver
    }

    /// Current result of the TLS handshake.
    var handshakeResult: InMemoryTLSHandshakeResult {
        handshakeObserver.result
    }

    /// Exact certificate-pin failure, when verification rejected the peer.
    var certificateVerificationFailure: String? {
        certificatePin.failureDescription
    }

    /// Processes ciphertext received from the underlying transport.
    ///
    /// Inbound TLS records may produce both decrypted application bytes and
    /// outbound control records such as handshake acknowledgements.
    func receiveEncryptedData(_ data: Data) async throws -> [Data] {
        guard !data.isEmpty else {
            throw RorkDeviceError.transport(
                "TLS transport returned an empty read."
            )
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            #if canImport(Dispatch)
            try await channel.writeInbound(buffer)
            await channel.testingEventLoop.run()
            try await channel.throwIfErrorCaught()
            #else
            try channel.writeInbound(buffer)
            channel.embeddedEventLoop.run()
            try channel.throwIfErrorCaught()
            #endif
            try await collectPlaintext()
            return try await takeOutboundData()
        } catch {
            throw normalize(error)
        }
    }

    /// Encrypts application bytes and returns the resulting TLS records.
    func sendPlaintext(_ data: Data) async throws -> [Data] {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            #if canImport(Dispatch)
            try await channel.writeOutbound(buffer)
            await channel.testingEventLoop.run()
            try await channel.throwIfErrorCaught()
            #else
            try channel.writeOutbound(buffer)
            channel.embeddedEventLoop.run()
            try channel.throwIfErrorCaught()
            #endif
            return try await takeOutboundData()
        } catch {
            throw normalize(error)
        }
    }

    /// Removes available plaintext up to the caller's capacity.
    func takePlaintext(upTo byteCount: Int) -> Data {
        guard !plaintextBuffer.isEmpty else {
            return Data()
        }
        let count = min(byteCount, plaintextBuffer.count)
        let data = Data(plaintextBuffer.prefix(count))
        plaintextBuffer.removeFirst(count)
        return data
    }

    /// Drains ciphertext currently emitted by NIO SSL.
    func takeOutboundData() async throws -> [Data] {
        var chunks: [Data] = []
        #if canImport(Dispatch)
        while let output = try await channel.readOutbound(as: IOData.self) {
            try appendOutboundData(output, to: &chunks)
        }
        #else
        while let output = try channel.readOutbound(as: IOData.self) {
            try appendOutboundData(output, to: &chunks)
        }
        #endif
        return chunks
    }

    /// Marks the embedded pipeline inactive after its transport closes.
    func close() async {
        #if canImport(Dispatch)
        _ = try? await channel.finish(acceptAlreadyClosed: true)
        #else
        closeEmbeddedTLSChannel(channel)
        #endif
    }

    /// Moves all decrypted channel output into the receive buffer.
    private func collectPlaintext() async throws {
        #if canImport(Dispatch)
        while let buffer = try await channel.readInbound(
            as: ByteBuffer.self
        ) {
            plaintextBuffer.append(contentsOf: buffer.readableBytesView)
        }
        #else
        while let buffer = try channel.readInbound(
            as: ByteBuffer.self
        ) {
            plaintextBuffer.append(contentsOf: buffer.readableBytesView)
        }
        #endif
    }

    /// Appends one encrypted NIO output buffer to a transport write batch.
    private func appendOutboundData(
        _ output: IOData,
        to chunks: inout [Data]
    ) throws {
        switch output {
        case .byteBuffer(let buffer):
            chunks.append(Data(buffer.readableBytesView))
        case .fileRegion:
            throw RorkDeviceError.secureSession(
                "TLS emitted an unsupported file-region write."
            )
        }
    }

    /// Preserves package error semantics around embedded NIO failures.
    private func normalize(_ error: Error) -> RorkDeviceError {
        if let deviceError = error as? RorkDeviceError {
            return deviceError
        }
        if let verificationFailure = certificatePin.failureDescription {
            return .secureSession(verificationFailure)
        }
        return .secureSession(
            "TLS session failed: \(describeTransportError(error))"
        )
    }
}

/// Activates an embedded TLS client and completes its scheduled startup work.
///
/// `EmbeddedChannel.connect(to:)` schedules `channelActive` on its manually
/// driven event loop. The loop must run before awaiting the connection future;
/// otherwise no handler can begin the TLS handshake or complete that future.
func activateEmbeddedTLSChannel(
    _ channel: EmbeddedChannel,
    connectingTo address: SocketAddress
) async throws {
    let connection = channel.eventLoop.makePromise(of: Void.self)
    channel.connect(to: address, promise: connection)
    channel.embeddedEventLoop.run()
    try await connection.futureResult.get()
    channel.embeddedEventLoop.run()
    try channel.throwIfErrorCaught()
}

/// Best-effort cleanup for the single-threaded embedded TLS channel.
///
/// `EmbeddedChannel.finish()` waits for the close future to complete. On WASI,
/// that wait is implemented as a precondition after one manual event-loop run,
/// so TLS handlers that defer close completion can trap the whole WASM module
/// during otherwise successful teardown. The browser path only needs to release
/// pending TLS cleanup work; errors are intentionally ignored because close is
/// called after the owning byte transport is already shutting down.
func closeEmbeddedTLSChannel(_ channel: EmbeddedChannel) {
    channel.close(promise: nil)
    channel.embeddedEventLoop.run()
    _ = try? channel.throwIfErrorCaught()
}

/// Sendable snapshot of an embedded TLS handshake.
private enum InMemoryTLSHandshakeResult: Sendable {
    /// More peer records are required.
    case pending

    /// NIO SSL completed the client handshake.
    case succeeded

    /// The handshake terminated before completion.
    case failed(String)
}

/// Captures TLS completion events emitted by the embedded pipeline.
///
/// NIO may invoke a handler from its event loop while the connection task reads
/// the result from another executor. Every mutable property is protected by
/// `lock`, which provides the synchronization the compiler cannot infer for a
/// `ChannelInboundHandler`.
private final class InMemoryTLSHandshakeObserver:
    ChannelInboundHandler,
    @unchecked Sendable
{
    /// Plaintext buffer type passed through after NIO SSL decrypts a record.
    typealias InboundIn = ByteBuffer

    /// Protects state read by the connection task.
    private let lock = NSLock()

    /// Current handshake result.
    private var storedResult = InMemoryTLSHandshakeResult.pending

    /// Thread-safe handshake result snapshot.
    var result: InMemoryTLSHandshakeResult {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    /// Records successful TLS negotiation.
    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let tlsEvent = event as? TLSUserEvent,
            case .handshakeCompleted = tlsEvent
        {
            complete(.succeeded)
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// Records an error while preserving normal pipeline propagation.
    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        complete(.failed(describeTransportError(error)))
        context.fireErrorCaught(error)
    }

    /// Records a peer close that occurs before negotiation completes.
    func channelInactive(context: ChannelHandlerContext) {
        complete(.failed("Connection closed during TLS handshake."))
        context.fireChannelInactive()
    }

    /// Stores the first terminal result.
    private func complete(_ result: InMemoryTLSHandshakeResult) {
        lock.lock()
        if case .pending = storedResult {
            storedResult = result
        }
        lock.unlock()
    }
}
