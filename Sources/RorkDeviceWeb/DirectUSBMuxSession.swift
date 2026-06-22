import Foundation
import RorkDevice

/// Bulk byte pipe between Swift and an Apple WebUSB interface.
///
/// The browser adapter owns interface discovery and endpoint transfers. This
/// protocol keeps the usbmux state machine independent of JavaScriptKit so its
/// framing, connection lifecycle, and failure behavior can be tested natively.
protocol DirectUSBMuxIO: Sendable {
    /// Reads at least one byte and at most `byteCount` bytes.
    func read(upTo byteCount: Int) async throws -> Data

    /// Writes one complete direct-usbmux packet.
    func write(_ data: Data) async throws

    /// Releases the claimed interface and terminates pending reads.
    func close() async
}

/// Multiplexes Lockdown and device-service streams over one direct USB pipe.
///
/// The actor owns packet sequencing and every virtual connection. It permits
/// one reader and one ordered writer per connection while safely interleaving
/// independent services such as heartbeat, AFC, and InstallationProxy.
actor DirectUSBMuxSession {
    /// Largest USB transfer requested from the browser.
    private static let readCapacity = 16 * 1_024

    /// Receive capacity advertised to the device after applying its fixed
    /// eight-bit window scale.
    private static let advertisedWindow = UInt16(
        UInt32(131_072) >> 8
    )

    /// Maximum service payload that fits in the device's sixteen-bit
    /// asynchronous USB message limit after both mux and TCP headers.
    private static let maximumPayloadLength =
        Int(UInt16.max) - 16 - DirectUSBMuxTCPPacket.headerLength

    /// Maximum unread data retained for one virtual connection.
    private static let maximumBufferedBytes = 8 * 1_024 * 1_024

    /// First host-side ephemeral port considered for a service connection.
    private static let firstEphemeralPort: UInt16 = 49_152

    /// Last host-side ephemeral port considered before wrapping.
    private static let lastEphemeralPort: UInt16 = 65_000

    /// Browser-owned USB bulk pipe.
    private let io: any DirectUSBMuxIO

    /// Maximum packet size reported by the host-to-device bulk endpoint.
    private let outboundUSBPacketSize: Int

    /// Maximum time allowed for direct-mux version negotiation.
    private let handshakeTimeout: Duration

    /// Maximum time allowed for each virtual service handshake.
    private let connectionTimeout: Duration

    /// Incremental decoder whose header format changes after negotiation.
    private var decoder = DirectUSBMuxPacketDecoder(
        headerFormat: .legacy
    )

    /// Packet serializer shared by negotiation and service traffic.
    private let packetCodec = DirectUSBMuxPacketCodec()

    /// Negotiated direct-mux major version.
    private var protocolVersion: UInt32?

    /// Sequence number placed in the next version-two mux header.
    private var transmitSequence: UInt16 = 0

    /// Device sequence value echoed in version-two mux headers.
    private var receiveSequence: UInt16 = 0xffff

    /// Next connection port candidate.
    private var nextEphemeralPort: UInt16 = 49_152

    /// Active and failed virtual service connections keyed by host port.
    private var connections: [UInt16: ConnectionState] = [:]

    /// Reader task that owns the USB input loop.
    private var readerTask: Task<Void, Never>?

    /// Continuation waiting for the device's version response.
    private var versionWaiter: VersionWaiter?

    /// Completed negotiation result retained across waiter races.
    private var versionResult: Result<UInt32, DirectUSBMuxError>?

    /// Monotonic token distinguishing a current version waiter from an expired
    /// timeout task.
    private var nextWaiterToken: UInt64 = 0

    /// Terminal transport failure, once observed.
    private var terminalError: DirectUSBMuxError?

    /// Creates and negotiates a direct USB mux session.
    ///
    /// The method returns only after the device has accepted version one or
    /// version two framing. Version two additionally sends the required setup
    /// packet before service connections can be opened.
    static func open(
        over io: any DirectUSBMuxIO,
        outboundUSBPacketSize: Int,
        handshakeTimeout: Duration = .seconds(5),
        connectionTimeout: Duration = .seconds(5)
    ) async throws -> DirectUSBMuxSession {
        guard outboundUSBPacketSize > 0 else {
            throw DirectUSBMuxError.invalidUSBPacketSize(
                outboundUSBPacketSize
            )
        }
        guard handshakeTimeout > .zero else {
            throw DirectUSBMuxError.invalidTimeout
        }
        guard connectionTimeout > .zero else {
            throw DirectUSBMuxError.invalidTimeout
        }

        let session = DirectUSBMuxSession(
            io: io,
            outboundUSBPacketSize: outboundUSBPacketSize,
            handshakeTimeout: handshakeTimeout,
            connectionTimeout: connectionTimeout
        )
        await session.startReading()
        do {
            try await session.negotiate()
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    /// Creates an unstarted session with validated timeout values.
    private init(
        io: any DirectUSBMuxIO,
        outboundUSBPacketSize: Int,
        handshakeTimeout: Duration,
        connectionTimeout: Duration
    ) {
        self.io = io
        self.outboundUSBPacketSize = outboundUSBPacketSize
        self.handshakeTimeout = handshakeTimeout
        self.connectionTimeout = connectionTimeout
    }

    /// Opens one device-side service port.
    ///
    /// Each returned connection has independent buffering and sequence state,
    /// while packet writes remain serialized through this actor and the USB
    /// pipe.
    func connect(
        to remotePort: UInt16
    ) async throws -> DirectUSBMuxConnection {
        try ensureActive()
        guard remotePort > 0 else {
            throw DirectUSBMuxError.invalidPort(remotePort)
        }

        let localPort = try allocateEphemeralPort()
        connections[localPort] = ConnectionState(
            remotePort: remotePort
        )

        do {
            try await sendTCPPacket(
                for: localPort,
                flags: [.synchronize],
                payload: Data()
            )
            try await waitUntilConnected(
                localPort: localPort,
                remotePort: remotePort
            )
            return DirectUSBMuxConnection(
                session: self,
                localPort: localPort,
                remotePort: remotePort
            )
        } catch {
            failConnection(
                on: localPort,
                with: normalizedError(error)
            )
            throw error
        }
    }

    /// Closes the complete USB session and every virtual service stream.
    func close() async {
        let readerTask = self.readerTask
        self.readerTask = nil
        readerTask?.cancel()
        finish(with: .transportClosed)
        await io.close()
    }

    /// Sends service bytes over an established virtual connection.
    func send(
        _ data: Data,
        on localPort: UInt16
    ) async throws {
        guard !data.isEmpty else {
            return
        }

        var offset = 0
        while offset < data.count {
            let capacity = try writableCapacity(for: localPort)
            if capacity == 0 {
                try await waitUntilWritable(on: localPort)
                continue
            }

            let chunkLength = payloadLengthAvoidingAlignedUSBTransfer(
                min(
                    data.count - offset,
                    capacity,
                    Self.maximumPayloadLength
                )
            )
            let chunk = Data(data[offset..<(offset + chunkLength)])
            guard var state = connections[localPort] else {
                throw DirectUSBMuxError.connectionClosed(
                    localPort: localPort
                )
            }
            let sequenceNumber = state.sendSequence
            state.sendSequence &+= UInt32(chunkLength)
            connections[localPort] = state
            try await sendTCPPacket(
                for: localPort,
                flags: [.acknowledgment],
                payload: chunk,
                sequenceNumber: sequenceNumber
            )
            offset += chunkLength
        }
    }

    /// Reduces a service chunk when its complete mux frame would end exactly
    /// on a USB packet boundary.
    ///
    /// WebUSB cannot request the zero-length packet that native USB stacks use
    /// to terminate aligned bulk transfers. Emitting another valid TCP frame
    /// preserves the service byte stream while ensuring the browser transfer
    /// ends with a short USB packet.
    private func payloadLengthAvoidingAlignedUSBTransfer(
        _ candidate: Int
    ) -> Int {
        let packetLength =
            DirectUSBMuxPacketHeaderFormat.sequenced.length
            + DirectUSBMuxTCPPacket.headerLength
            + candidate
        guard candidate > 1,
            packetLength.isMultiple(of: outboundUSBPacketSize)
        else {
            return candidate
        }
        return candidate - 1
    }

    /// Returns currently available service bytes up to the requested capacity.
    func receive(
        on localPort: UInt16,
        upTo byteCount: Int
    ) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput(
                "Receive byte count cannot be negative."
            )
        }
        guard byteCount > 0 else {
            return Data()
        }
        guard var state = connections[localPort] else {
            throw DirectUSBMuxError.connectionClosed(
                localPort: localPort
            )
        }

        switch state.phase {
        case .connecting:
            throw DirectUSBMuxError.connectionNotReady(
                localPort: localPort
            )
        case .connected:
            break
        case .failed(let error):
            throw error
        }

        if !state.inboundData.isEmpty {
            let count = min(byteCount, state.inboundData.count)
            let data = Data(state.inboundData.prefix(count))
            state.inboundData.removeFirst(count)
            connections[localPort] = state
            return data
        }

        precondition(
            state.readWaiter == nil,
            "Direct USB mux connections support one active reader."
        )
        return try await withCheckedThrowingContinuation {
            state.readWaiter = ReadWaiter(
                maximumByteCount: byteCount,
                continuation: $0
            )
            connections[localPort] = state
        }
    }

    /// Closes one service connection without affecting other open streams.
    func closeConnection(on localPort: UInt16) async {
        guard let state = connections[localPort] else {
            return
        }
        if case .connected = state.phase {
            try? await sendTCPPacket(
                for: localPort,
                flags: [.reset],
                payload: Data()
            )
        }
        failConnection(
            on: localPort,
            with: .connectionClosed(localPort: localPort)
        )
        connections.removeValue(forKey: localPort)
    }

    /// Starts the single USB input task.
    private func startReading() {
        precondition(readerTask == nil)
        readerTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    /// Negotiates the packet header version and completes setup.
    private func negotiate() async throws {
        var payload = Data(capacity: 12)
        payload.appendBigEndian(UInt32(2))
        payload.appendBigEndian(UInt32(0))
        payload.appendBigEndian(UInt32(0))
        try await sendMuxPacket(
            protocol: .version,
            payload: payload,
            forceLegacyHeader: true
        )

        let version = try await waitForVersion()
        guard version == 1 || version == 2 else {
            throw DirectUSBMuxError.unsupportedVersion(version)
        }
        if version >= 2 {
            try await sendMuxPacket(
                protocol: .setup,
                payload: Data([0x07]),
                resetSequences: true
            )
        }
    }

    /// Reads USB transfers until cancellation or a terminal transport failure.
    private func runReadLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await io.read(
                    upTo: Self.readCapacity
                )
                guard !data.isEmpty else {
                    throw DirectUSBMuxError.transportClosed
                }
                try await process(data)
            }
        } catch is CancellationError {
            return
        } catch {
            let error = normalizedError(error)
            finish(with: error)
            await io.close()
        }
    }

    /// Decodes every complete packet contained in one USB transfer.
    private func process(_ data: Data) async throws {
        decoder.append(data)
        while let packet = try decoder.nextPacket() {
            recordReceiveSequence(from: packet.header)
            switch packet.protocol {
            case .version:
                try handleVersionPacket(packet.payload)
            case .control:
                try handleControlPacket(packet.payload)
            case .setup:
                continue
            case .tcp:
                try await handleTCPPacket(
                    DirectUSBMuxTCPPacket.decode(packet.payload)
                )
            }
        }
    }

    /// Records the sequence value the device expects the host to acknowledge.
    ///
    /// Version-two headers carry transport-level sequence state independently
    /// of the virtual TCP stream. Every later host packet must echo the latest
    /// receive value supplied by the device.
    private func recordReceiveSequence(
        from header: DirectUSBMuxPacketHeader
    ) {
        guard case .sequenced(_, let receiveSequence) = header else {
            return
        }
        self.receiveSequence = receiveSequence
    }

    /// Applies the device's initial negotiated direct-mux version.
    ///
    /// Some devices emit another version frame after setup. Framing is already
    /// established at that point, so the duplicate must not reset or terminate
    /// active service connections.
    private func handleVersionPacket(_ payload: Data) throws {
        guard protocolVersion == nil else {
            return
        }
        guard payload.count >= 12 else {
            throw DirectUSBMuxError.invalidVersionPacket
        }
        let version = payload.bigEndianInteger(
            at: 0,
            as: UInt32.self
        )
        guard version == 1 || version == 2 else {
            throw DirectUSBMuxError.unsupportedVersion(version)
        }

        protocolVersion = version
        if version >= 2 {
            decoder.useHeaderFormat(.sequenced)
        }
        versionResult = .success(version)
        if let waiter = versionWaiter {
            versionWaiter = nil
            waiter.continuation.resume(returning: version)
        }
    }

    /// Rejects device-side control errors while ignoring diagnostic notices.
    private func handleControlPacket(_ payload: Data) throws {
        guard let type = payload.first else {
            return
        }
        guard type == 3 else {
            return
        }
        let message = String(
            decoding: payload.dropFirst(),
            as: UTF8.self
        )
        throw DirectUSBMuxError.deviceControlError(message)
    }

    /// Routes one TCP-compatible packet to its virtual connection.
    private func handleTCPPacket(
        _ packet: DirectUSBMuxTCPPacket
    ) async throws {
        let localPort = packet.destinationPort
        guard var state = connections[localPort],
            state.remotePort == packet.sourcePort
        else {
            if !packet.flags.contains(.reset) {
                try await sendAnonymousReset(for: packet)
            }
            return
        }

        if packet.flags.contains(.reset) {
            let reason = resetReason(from: packet.payload)
            failConnection(
                on: localPort,
                with: .connectionReset(
                    localPort: localPort,
                    remotePort: state.remotePort,
                    reason: reason
                )
            )
            return
        }

        switch state.phase {
        case .connecting:
            let expectedFlags: DirectUSBMuxTCPFlags = [
                .synchronize,
                .acknowledgment,
            ]
            guard packet.flags == expectedFlags else {
                failConnection(
                    on: localPort,
                    with: .connectionRefused(
                        localPort: localPort,
                        remotePort: state.remotePort
                    )
                )
                return
            }
            let expectedAcknowledgment = state.sendSequence &+ 1
            guard packet.acknowledgmentNumber == expectedAcknowledgment else {
                await rejectInvalidAcknowledgment(
                    packet.acknowledgmentNumber,
                    for: localPort,
                    state: state
                )
                return
            }

            state.phase = .connected
            state.sendSequence = expectedAcknowledgment
            state.peerAcknowledgment = packet.acknowledgmentNumber
            state.peerWindow = UInt32(packet.windowSize) << 8
            state.receiveSequence = packet.sequenceNumber &+ 1
            let waiter = state.connectWaiter
            state.connectWaiter = nil
            connections[localPort] = state

            try await sendTCPPacket(
                for: localPort,
                flags: [.acknowledgment],
                payload: Data()
            )
            waiter?.continuation.resume()

        case .connected:
            guard
                !sequence(
                    packet.acknowledgmentNumber,
                    isAfter: state.sendSequence
                )
            else {
                await rejectInvalidAcknowledgment(
                    packet.acknowledgmentNumber,
                    for: localPort,
                    state: state
                )
                return
            }
            if packet.acknowledgmentNumber == state.peerAcknowledgment
                || sequence(
                    packet.acknowledgmentNumber,
                    isAfter: state.peerAcknowledgment
                )
            {
                state.peerAcknowledgment = packet.acknowledgmentNumber
                state.peerWindow = UInt32(packet.windowSize) << 8
                let writeWaiters = state.writeWaiters
                state.writeWaiters.removeAll()
                connections[localPort] = state
                for waiter in writeWaiters {
                    waiter.resume()
                }
            }

            if packet.flags.contains(.finish) {
                failConnection(
                    on: localPort,
                    with: .connectionClosed(localPort: localPort)
                )
                return
            }
            if packet.payload.isEmpty {
                return
            }

            guard packet.sequenceNumber == state.receiveSequence else {
                if sequence(
                    state.receiveSequence,
                    isAfter: packet.sequenceNumber
                ) {
                    try await sendTCPPacket(
                        for: localPort,
                        flags: [.acknowledgment],
                        payload: Data()
                    )
                    return
                }
                failConnection(
                    on: localPort,
                    with: .outOfOrderData(
                        localPort: localPort,
                        expectedSequence: state.receiveSequence,
                        actualSequence: packet.sequenceNumber
                    )
                )
                return
            }

            state.receiveSequence &+= UInt32(packet.payload.count)
            do {
                try appendInboundData(
                    packet.payload,
                    to: &state,
                    localPort: localPort
                )
            } catch let error as DirectUSBMuxError {
                connections[localPort] = state
                try? await sendTCPPacket(
                    for: localPort,
                    flags: [.reset],
                    payload: Data()
                )
                failConnection(
                    on: localPort,
                    with: error
                )
                return
            }
            connections[localPort] = state
            try await sendTCPPacket(
                for: localPort,
                flags: [.acknowledgment],
                payload: Data()
            )

        case .failed:
            return
        }
    }

    /// Rejects an ACK that advances beyond bytes sent by the host.
    private func rejectInvalidAcknowledgment(
        _ acknowledgment: UInt32,
        for localPort: UInt16,
        state: ConnectionState
    ) async {
        try? await sendTCPPacket(
            for: localPort,
            flags: [.reset],
            payload: Data()
        )
        failConnection(
            on: localPort,
            with: .invalidAcknowledgment(
                localPort: localPort,
                sentSequence: state.sendSequence,
                acknowledgedSequence: acknowledgment
            )
        )
    }

    /// Compares wrapping TCP sequence numbers within the half-range rule.
    private func sequence(
        _ candidate: UInt32,
        isAfter reference: UInt32
    ) -> Bool {
        let distance = candidate &- reference
        return distance != 0 && distance < (UInt32(1) << 31)
    }

    /// Buffers received service data or fulfills a suspended reader.
    private func appendInboundData(
        _ data: Data,
        to state: inout ConnectionState,
        localPort: UInt16
    ) throws {
        if let waiter = state.readWaiter {
            state.readWaiter = nil
            let count = min(
                waiter.maximumByteCount,
                data.count
            )
            waiter.continuation.resume(
                returning: Data(data.prefix(count))
            )
            if count < data.count {
                state.inboundData.append(data.dropFirst(count))
            }
        } else {
            state.inboundData.append(data)
        }

        guard state.inboundData.count <= Self.maximumBufferedBytes else {
            throw DirectUSBMuxError.receiveBufferOverflow(
                localPort: localPort,
                maximumByteCount: Self.maximumBufferedBytes
            )
        }
    }

    /// Sends one mux packet with the currently negotiated header.
    private func sendMuxPacket(
        protocol muxProtocol: DirectUSBMuxProtocol,
        payload: Data,
        forceLegacyHeader: Bool = false,
        resetSequences: Bool = false
    ) async throws {
        let header: DirectUSBMuxPacketHeader
        if forceLegacyHeader || (protocolVersion ?? 0) < 2 {
            header = .legacy
        } else {
            if resetSequences {
                transmitSequence = 0
                receiveSequence = 0xffff
            }
            header = .sequenced(
                transmitSequence: transmitSequence,
                receiveSequence: receiveSequence
            )
            transmitSequence &+= 1
        }

        try await io.write(
            packetCodec.encode(
                protocol: muxProtocol,
                payload: payload,
                header: header
            )
        )
    }

    /// Sends a TCP-compatible frame for one active connection.
    private func sendTCPPacket(
        for localPort: UInt16,
        flags: DirectUSBMuxTCPFlags,
        payload: Data,
        sequenceNumber: UInt32? = nil
    ) async throws {
        guard let state = connections[localPort] else {
            throw DirectUSBMuxError.connectionClosed(
                localPort: localPort
            )
        }
        try await sendMuxPacket(
            protocol: .tcp,
            payload: DirectUSBMuxTCPPacket(
                sourcePort: localPort,
                destinationPort: state.remotePort,
                sequenceNumber: sequenceNumber ?? state.sendSequence,
                acknowledgmentNumber: state.receiveSequence,
                flags: flags,
                windowSize: Self.advertisedWindow,
                payload: payload
            ).encoded()
        )
    }

    /// Rejects traffic for a virtual connection the host does not own.
    private func sendAnonymousReset(
        for packet: DirectUSBMuxTCPPacket
    ) async throws {
        try await sendMuxPacket(
            protocol: .tcp,
            payload: DirectUSBMuxTCPPacket(
                sourcePort: packet.destinationPort,
                destinationPort: packet.sourcePort,
                sequenceNumber: 0,
                acknowledgmentNumber: packet.sequenceNumber,
                flags: [.reset],
                windowSize: 0,
                payload: Data()
            ).encoded()
        )
    }

    /// Suspends until the version response or handshake deadline.
    private func waitForVersion() async throws -> UInt32 {
        if let versionResult {
            return try versionResult.get()
        }

        nextWaiterToken &+= 1
        let token = nextWaiterToken
        let timeout = handshakeTimeout
        Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOutVersionWaiter(token: token)
        }
        return try await withCheckedThrowingContinuation {
            versionWaiter = VersionWaiter(
                token: token,
                continuation: $0
            )
        }
    }

    /// Fails the active version waiter after its deadline.
    private func timeOutVersionWaiter(token: UInt64) {
        guard let waiter = versionWaiter,
            waiter.token == token
        else {
            return
        }
        versionWaiter = nil
        versionResult = .failure(.handshakeTimedOut)
        waiter.continuation.resume(
            throwing: DirectUSBMuxError.handshakeTimedOut
        )
    }

    /// Suspends until a service SYN receives its SYN-ACK or deadline.
    private func waitUntilConnected(
        localPort: UInt16,
        remotePort: UInt16
    ) async throws {
        nextWaiterToken &+= 1
        let token = nextWaiterToken
        let timeout = connectionTimeout
        Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOutConnection(
                localPort: localPort,
                remotePort: remotePort,
                token: token
            )
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            guard var state = connections[localPort] else {
                continuation.resume(
                    throwing: DirectUSBMuxError.connectionClosed(
                        localPort: localPort
                    )
                )
                return
            }
            switch state.phase {
            case .connected:
                continuation.resume()
            case .failed(let error):
                continuation.resume(throwing: error)
            case .connecting:
                state.connectWaiter = ConnectWaiter(
                    token: token,
                    continuation: continuation
                )
                connections[localPort] = state
            }
        }
    }

    /// Fails a connection whose SYN did not receive a timely response.
    private func timeOutConnection(
        localPort: UInt16,
        remotePort: UInt16,
        token: UInt64
    ) {
        guard let state = connections[localPort],
            case .connecting = state.phase,
            state.connectWaiter?.token == token
        else {
            return
        }
        failConnection(
            on: localPort,
            with: .connectionTimedOut(
                localPort: localPort,
                remotePort: remotePort
            )
        )
    }

    /// Returns service bytes currently permitted by the device's receive window.
    private func writableCapacity(
        for localPort: UInt16
    ) throws -> Int {
        guard let state = connections[localPort] else {
            throw DirectUSBMuxError.connectionClosed(
                localPort: localPort
            )
        }
        switch state.phase {
        case .connecting:
            throw DirectUSBMuxError.connectionNotReady(
                localPort: localPort
            )
        case .failed(let error):
            throw error
        case .connected:
            let inFlight =
                state.sendSequence &- state.peerAcknowledgment
            guard state.peerWindow > inFlight else {
                return 0
            }
            return Int(state.peerWindow - inFlight)
        }
    }

    /// Suspends a writer until an ACK changes its available window.
    private func waitUntilWritable(
        on localPort: UInt16
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            guard var state = connections[localPort] else {
                continuation.resume(
                    throwing: DirectUSBMuxError.connectionClosed(
                        localPort: localPort
                    )
                )
                return
            }
            switch state.phase {
            case .failed(let error):
                continuation.resume(throwing: error)
            case .connecting:
                continuation.resume(
                    throwing: DirectUSBMuxError.connectionNotReady(
                        localPort: localPort
                    )
                )
            case .connected:
                state.writeWaiters.append(continuation)
                connections[localPort] = state
            }
        }
    }

    /// Allocates a host port not used by another virtual connection.
    private func allocateEphemeralPort() throws -> UInt16 {
        let candidateCount =
            Int(Self.lastEphemeralPort - Self.firstEphemeralPort) + 1
        for _ in 0..<candidateCount {
            let candidate = nextEphemeralPort
            if nextEphemeralPort == Self.lastEphemeralPort {
                nextEphemeralPort = Self.firstEphemeralPort
            } else {
                nextEphemeralPort &+= 1
            }
            if connections[candidate] == nil {
                return candidate
            }
        }
        throw DirectUSBMuxError.noAvailablePorts
    }

    /// Fails one virtual connection and resolves all of its waiters.
    private func failConnection(
        on localPort: UInt16,
        with error: DirectUSBMuxError
    ) {
        guard var state = connections[localPort] else {
            return
        }
        state.phase = .failed(error)
        let connectWaiter = state.connectWaiter
        let readWaiter = state.readWaiter
        let writeWaiters = state.writeWaiters
        state.connectWaiter = nil
        state.readWaiter = nil
        state.writeWaiters.removeAll()
        connections[localPort] = state

        connectWaiter?.continuation.resume(throwing: error)
        readWaiter?.continuation.resume(throwing: error)
        for waiter in writeWaiters {
            waiter.resume(throwing: error)
        }
    }

    /// Marks the complete session terminal and resolves every waiter.
    private func finish(with error: DirectUSBMuxError) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        versionResult = .failure(error)

        let versionWaiter = self.versionWaiter
        self.versionWaiter = nil
        versionWaiter?.continuation.resume(throwing: error)

        for localPort in Array(connections.keys) {
            failConnection(on: localPort, with: error)
        }
    }

    /// Rejects operations after negotiation or transport failure.
    private func ensureActive() throws {
        if let terminalError {
            throw terminalError
        }
        guard protocolVersion != nil else {
            throw DirectUSBMuxError.sessionNotReady
        }
    }

    /// Converts arbitrary USB adapter failures into a stable transport error.
    private func normalizedError(_ error: Error) -> DirectUSBMuxError {
        if let error = error as? DirectUSBMuxError {
            return error
        }
        return .transport(String(describing: error))
    }

    /// Extracts the optional textual reason carried by some reset packets.
    private func resetReason(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        let reason = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }
}

/// `DeviceTransport` adapter retained by browser-facing sessions.
struct DirectUSBMuxTransport: DeviceTransport, Sendable {
    /// Multiplexed session shared by Lockdown and later services.
    let session: DirectUSBMuxSession

    /// Opens one device-side service stream.
    func connect(to port: UInt16) async throws -> DeviceConnection {
        try await session.connect(to: port)
    }

    /// Closes the USB interface and every virtual connection.
    func close() async {
        await session.close()
    }
}

/// One full-duplex service stream inside a direct USB mux session.
final class DirectUSBMuxConnection:
    StreamingDeviceConnection,
    Sendable
{
    /// Owning mux session.
    private let session: DirectUSBMuxSession

    /// Serializes complete application writes on this connection.
    private let writer: DirectUSBMuxConnectionWriter

    /// Host-side port identifying the stream.
    let localPort: UInt16

    /// Device-side service port.
    let remotePort: UInt16

    /// Creates a connection after its SYN handshake has completed.
    init(
        session: DirectUSBMuxSession,
        localPort: UInt16,
        remotePort: UInt16
    ) {
        self.session = session
        self.localPort = localPort
        self.remotePort = remotePort
        writer = DirectUSBMuxConnectionWriter(
            session: session,
            localPort: localPort
        )
    }

    /// Sends one complete service buffer without interleaving another write.
    func send(_ data: Data) async throws {
        try await writer.send(data)
    }

    /// Receives exactly the requested number of service bytes.
    func receive(exactly byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RorkDeviceError.invalidInput(
                "Receive byte count cannot be negative."
            )
        }
        var data = Data(capacity: byteCount)
        while data.count < byteCount {
            data.append(
                try await receive(
                    upTo: byteCount - data.count
                )
            )
        }
        return data
    }

    /// Receives available service bytes up to the requested capacity.
    func receive(upTo byteCount: Int) async throws -> Data {
        try await session.receive(
            on: localPort,
            upTo: byteCount
        )
    }

    /// Schedules teardown of this virtual stream.
    func close() {
        Task {
            await session.closeConnection(on: localPort)
        }
    }
}

/// Serializes writes issued through one public connection object.
private actor DirectUSBMuxConnectionWriter {
    /// Owning mux session.
    private let session: DirectUSBMuxSession

    /// Host-side port identifying the stream.
    private let localPort: UInt16

    /// Creates a writer for one virtual connection.
    init(
        session: DirectUSBMuxSession,
        localPort: UInt16
    ) {
        self.session = session
        self.localPort = localPort
    }

    /// Forwards one application buffer after prior writes complete.
    func send(_ data: Data) async throws {
        try await session.send(data, on: localPort)
    }
}

/// Mutable state for one virtual device-service connection.
private struct ConnectionState {
    /// Device-side service port.
    let remotePort: UInt16

    /// Current connection handshake or terminal state.
    var phase = ConnectionPhase.connecting

    /// Sequence number assigned to the next outbound byte.
    var sendSequence: UInt32 = 0

    /// Sequence number expected from the next inbound byte.
    var receiveSequence: UInt32 = 0

    /// Latest outbound sequence acknowledged by the device.
    var peerAcknowledgment: UInt32 = 0

    /// Device receive window after applying the fixed scale.
    var peerWindow: UInt32 = 0

    /// Bytes received before the caller requested them.
    var inboundData = Data()

    /// Task waiting for the initial SYN-ACK.
    var connectWaiter: ConnectWaiter?

    /// Single suspended protocol reader.
    var readWaiter: ReadWaiter?

    /// Writers waiting for the device window to advance.
    var writeWaiters: [CheckedContinuation<Void, Error>] = []
}

/// Lifecycle of one virtual device-service connection.
private enum ConnectionPhase {
    /// SYN sent; waiting for SYN-ACK.
    case connecting

    /// Full-duplex service traffic is permitted.
    case connected

    /// The stream reached a terminal error.
    case failed(DirectUSBMuxError)
}

/// Version-negotiation continuation and its timeout identity.
private struct VersionWaiter {
    /// Token used to ignore a stale timeout task.
    let token: UInt64

    /// Suspended negotiation call.
    let continuation: CheckedContinuation<UInt32, Error>
}

/// Service-handshake continuation and its timeout identity.
private struct ConnectWaiter {
    /// Token used to ignore a stale timeout task.
    let token: UInt64

    /// Suspended connection call.
    let continuation: CheckedContinuation<Void, Error>
}

/// Pending short read on one virtual service connection.
private struct ReadWaiter {
    /// Maximum bytes accepted by the caller.
    let maximumByteCount: Int

    /// Suspended receive operation.
    let continuation: CheckedContinuation<Data, Error>
}

/// Stable failures produced by the direct WebUSB mux transport.
enum DirectUSBMuxError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    /// A caller supplied a non-positive timeout.
    case invalidTimeout

    /// Browser descriptor reported an unusable bulk-endpoint packet size.
    case invalidUSBPacketSize(Int)

    /// A caller requested reserved device port zero.
    case invalidPort(UInt16)

    /// Version response did not contain its fixed payload.
    case invalidVersionPacket

    /// Device selected an unsupported direct-mux major version.
    case unsupportedVersion(UInt32)

    /// Device did not answer the version request before the deadline.
    case handshakeTimedOut

    /// Service connection did not receive SYN-ACK before the deadline.
    case connectionTimedOut(
        localPort: UInt16,
        remotePort: UInt16
    )

    /// Device rejected the service connection handshake.
    case connectionRefused(
        localPort: UInt16,
        remotePort: UInt16
    )

    /// Device reset an established service connection.
    case connectionReset(
        localPort: UInt16,
        remotePort: UInt16,
        reason: String?
    )

    /// A service operation ran before its handshake completed.
    case connectionNotReady(localPort: UInt16)

    /// A service connection has already closed.
    case connectionClosed(localPort: UInt16)

    /// Reliable USB delivery produced a sequence gap.
    case outOfOrderData(
        localPort: UInt16,
        expectedSequence: UInt32,
        actualSequence: UInt32
    )

    /// Device acknowledged bytes the host has not sent.
    case invalidAcknowledgment(
        localPort: UInt16,
        sentSequence: UInt32,
        acknowledgedSequence: UInt32
    )

    /// A caller stopped consuming inbound service data.
    case receiveBufferOverflow(
        localPort: UInt16,
        maximumByteCount: Int
    )

    /// Every host-side ephemeral port is active.
    case noAvailablePorts

    /// A device-side control frame reported a transport error.
    case deviceControlError(String)

    /// Service operations began before version negotiation completed.
    case sessionNotReady

    /// USB interface was released or disconnected.
    case transportClosed

    /// Browser adapter returned another USB transport failure.
    case transport(String)

    /// Human-readable message suitable for browser UI and diagnostics.
    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "Direct USB mux timeouts must be greater than zero."
        case .invalidUSBPacketSize(let byteCount):
            return "Direct USB mux packet size \(byteCount) is invalid."
        case .invalidPort(let port):
            return "Device service port \(port) is invalid."
        case .invalidVersionPacket:
            return "The device returned an invalid direct USB mux version packet."
        case .unsupportedVersion(let version):
            return "The device selected unsupported direct USB mux version \(version)."
        case .handshakeTimedOut:
            return "The device did not complete direct USB mux negotiation in time."
        case .connectionTimedOut(let localPort, let remotePort):
            return "The device service connection \(localPort)->\(remotePort) timed out."
        case .connectionRefused(let localPort, let remotePort):
            return "The device refused service connection \(localPort)->\(remotePort)."
        case .connectionReset(let localPort, let remotePort, let reason):
            if let reason {
                return "The device reset service connection \(localPort)->\(remotePort): \(reason)"
            }
            return "The device reset service connection \(localPort)->\(remotePort)."
        case .connectionNotReady(let localPort):
            return "Device service connection \(localPort) is not ready."
        case .connectionClosed(let localPort):
            return "Device service connection \(localPort) is closed."
        case .outOfOrderData(let localPort, let expected, let actual):
            return
                "Device service connection \(localPort) expected sequence \(expected) but received \(actual)."
        case .invalidAcknowledgment(let localPort, let sent, let acknowledged):
            return
                "Device service connection \(localPort) acknowledged sequence \(acknowledged) after sent sequence \(sent)."
        case .receiveBufferOverflow(let localPort, let maximumByteCount):
            return
                "Device service connection \(localPort) exceeded its \(maximumByteCount)-byte receive buffer."
        case .noAvailablePorts:
            return "No direct USB mux service ports are available."
        case .deviceControlError(let message):
            return "The device reported a direct USB mux error: \(message)"
        case .sessionNotReady:
            return "The direct USB mux session is not ready."
        case .transportClosed:
            return "The direct USB connection is closed."
        case .transport(let message):
            return "Direct USB transport error: \(message)"
        }
    }
}
