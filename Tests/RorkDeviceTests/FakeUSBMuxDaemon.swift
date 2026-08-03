import Foundation
import NIOCore

@testable import RorkDevice

/// Thread-safe socket daemon used to exercise usbmux and Lockdown workflows.
///
/// Each accepted channel owns its protocol state. Immutable fixtures never
/// change after initialization, while the lock protects lifecycle flags and
/// recorded requests shared with test assertions.
final class FakeUSBMuxDaemon: @unchecked Sendable {
    private var server: NIOTestServer?
    private let secureLockdown: Bool
    private let secureServices: Set<String>
    private let devices: [USBMuxDevice]
    private let deviceEvents: [USBMuxDeviceEvent]
    private let listenResponse: [String: Any]
    private let pairingRecordData: Data?
    private let systemBUID: String
    private let devicePublicKey: Data
    private let wiFiMACAddress: String

    /// Lockdown response returned after recording an Unpair request.
    ///
    /// Tests inject failures here to verify that host credentials are retained
    /// when the device does not confirm trust removal.
    private let unpairingResponse: [String: Any]

    /// Optional usbmux result code included with a pairing-record response.
    private let pairingRecordStatus: Int?

    /// Optional usbmux result code returned after saving a pairing record.
    private let savePairingRecordStatus: Int

    /// usbmux result code returned after removing a pairing record.
    ///
    /// Zero represents success; nonzero values exercise error propagation from
    /// the host-record cleanup stage.
    private let removePairingRecordStatus: Int

    /// Keeps a Listen socket readable until the client closes it.
    private let keepListenOpenAfterEvents: Bool
    private let lock = NSLock()
    private var stopped = false
    /// Whether a Listen request reached the fake daemon.
    private var _listenConnectionOpen = false
    /// Whether the client closed the long-lived Listen socket.
    private var _listenPeerClosed = false
    private var _connectedPorts: [UInt16] = []
    private var _afcOperations: [UInt64] = []
    private var _installedPackagePaths: [String] = []
    private var _misagentMessageTypes: [String] = []
    private var _servicesStartedWithEscrow: [String] = []
    private var _heartbeatReplies: [String] = []
    private var _houseArrestRequests: [[String: String]] = []
    private var _savedPairingRecordData: Data?
    private var _savedPairingRecordIdentifier: String?
    private var _savedPairingRecordDeviceID: UInt32?

    /// Device identifier from the most recent DeletePairRecord request.
    private var _removedPairingRecordIdentifier: String?

    /// Host identifier from the most recent Lockdown Unpair request.
    private var _unpairedHostIdentifier: String?
    private var pairingResponses: [[String: Any]]
    private var _pairingAttemptCount = 0

    var port: UInt16 {
        server?.port ?? 0
    }

    var connectedPorts: [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        return _connectedPorts
    }

    /// True after the fake daemon receives a Listen request.
    var listenConnectionOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _listenConnectionOpen
    }

    /// True after the client closes a held-open Listen connection.
    var listenPeerClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _listenPeerClosed
    }

    var afcOperations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return _afcOperations
    }

    var installedPackagePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _installedPackagePaths
    }

    var misagentMessageTypes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _misagentMessageTypes
    }

    var servicesStartedWithEscrow: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _servicesStartedWithEscrow
    }

    var heartbeatReplies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _heartbeatReplies
    }

    var houseArrestRequests: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return _houseArrestRequests
    }

    var savedPairingRecordData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _savedPairingRecordData
    }

    var savedPairingRecordIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return _savedPairingRecordIdentifier
    }

    /// Active usbmux attachment associated with the saved pairing record.
    var savedPairingRecordDeviceID: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return _savedPairingRecordDeviceID
    }

    /// Device identifier whose host pairing record was removed.
    var removedPairingRecordIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return _removedPairingRecordIdentifier
    }

    /// Host identifier whose device-side trust was revoked.
    var unpairedHostIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return _unpairedHostIdentifier
    }

    var pairingAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _pairingAttemptCount
    }

    init(
        secureLockdown: Bool = false,
        secureServices: Set<String> = [],
        devices: [USBMuxDevice] = [
            USBMuxDevice(
                deviceID: 1,
                serialNumber: "fake-device-1",
                properties: ["ConnectionType": "USB"]
            )
        ],
        deviceEvents: [USBMuxDeviceEvent] = [],
        listenResponse: [String: Any] = ["Number": 0],
        pairingRecordData: Data? = nil,
        pairingRecordStatus: Int? = nil,
        systemBUID: String = "fake-system-buid",
        savePairingRecordStatus: Int = 0,
        removePairingRecordStatus: Int = 0,
        devicePublicKey: Data = testDevicePublicKeyPEM,
        wiFiMACAddress: String = "00:11:22:33:44:55",
        pairingResponses: [[String: Any]] = [],
        unpairingResponse: [String: Any] = [
            "Request": "Unpair"
        ],
        keepListenOpenAfterEvents: Bool = false
    ) throws {
        self.secureLockdown = secureLockdown
        self.secureServices = secureServices
        self.devices = devices
        self.deviceEvents = deviceEvents
        self.listenResponse = listenResponse
        self.pairingRecordData = pairingRecordData
        self.pairingRecordStatus = pairingRecordStatus
        self.systemBUID = systemBUID
        self.savePairingRecordStatus = savePairingRecordStatus
        self.removePairingRecordStatus = removePairingRecordStatus
        self.devicePublicKey = devicePublicKey
        self.wiFiMACAddress = wiFiMACAddress
        self.pairingResponses = pairingResponses
        self.unpairingResponse = unpairingResponse
        self.keepListenOpenAfterEvents = keepListenOpenAfterEvents
        server = try NIOTestServer { [weak self] channel in
            guard let self else {
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            return channel.pipeline.addHandler(
                ClientHandler(daemon: self)
            )
        }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            server?.stop()
            server = nil
        }
    }

    private func recordListenConnectionOpen() {
        lock.lock()
        _listenConnectionOpen = true
        lock.unlock()
    }

    private func recordListenPeerClosed() {
        lock.lock()
        _listenPeerClosed = true
        lock.unlock()
    }

    private final class ClientHandler:
        ChannelInboundHandler,
        @unchecked Sendable
    {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private enum State {
            case usbmux
            case listen
            case lockdown
            case afc
            case installationProxy
            case misagent
            case heartbeat
            case houseArrest
            case closed
        }

        private let daemon: FakeUSBMuxDaemon
        private var state = State.usbmux
        private var inbound = ByteBuffer()

        init(daemon: FakeUSBMuxDaemon) {
            self.daemon = daemon
        }

        func channelRead(
            context: ChannelHandlerContext,
            data: NIOAny
        ) {
            var bytes = unwrapInboundIn(data)
            inbound.writeBuffer(&bytes)
            while processNextMessage(context: context) {}
        }

        func channelInactive(context: ChannelHandlerContext) {
            if state == .listen {
                daemon.recordListenPeerClosed()
            }
            context.fireChannelInactive()
        }

        func errorCaught(
            context: ChannelHandlerContext,
            error _: Error
        ) {
            state = .closed
            context.close(promise: nil)
        }

        private func processNextMessage(
            context: ChannelHandlerContext
        ) -> Bool {
            switch state {
            case .usbmux:
                return processUSBMuxRequest(context: context)
            case .lockdown:
                return processLockdownRequest(context: context)
            case .afc:
                return processAFCRequest(context: context)
            case .installationProxy:
                return processInstallationProxyRequest(context: context)
            case .misagent:
                return processMISAgentRequest(context: context)
            case .heartbeat:
                return processHeartbeatRequest(context: context)
            case .houseArrest:
                return processHouseArrestRequest(context: context)
            case .listen, .closed:
                return false
            }
        }

        private func processUSBMuxRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard let request = readUSBMuxRequest() else {
                return false
            }

            switch request.dictionary["MessageType"] as? String {
            case "ListDevices":
                let deviceList: [[String: Any]] = daemon.devices.map {
                    device in
                    var properties = device.properties
                    properties["SerialNumber"] = device.serialNumber
                    return [
                        "DeviceID": device.deviceID,
                        "Properties": properties,
                    ]
                }
                sendUSBMuxResponse(
                    ["DeviceList": deviceList],
                    tag: request.packet.tag,
                    context: context
                )
            case "Listen":
                daemon.recordListenConnectionOpen()
                sendUSBMuxResponse(
                    daemon.listenResponse,
                    tag: request.packet.tag,
                    context: context
                )
                for event in daemon.deviceEvents {
                    sendUSBMuxEvent(event, context: context)
                }
                if daemon.keepListenOpenAfterEvents {
                    state = .listen
                } else {
                    close(context: context)
                }
            case "ReadPairRecord":
                guard let pairingRecordData = daemon.pairingRecordData
                else {
                    sendUSBMuxResponse(
                        ["Number": 2],
                        tag: request.packet.tag,
                        context: context
                    )
                    return true
                }
                var response: [String: Any] = [
                    "PairRecordData": pairingRecordData
                ]
                if let pairingRecordStatus = daemon.pairingRecordStatus {
                    response["Number"] = pairingRecordStatus
                }
                sendUSBMuxResponse(
                    response,
                    tag: request.packet.tag,
                    context: context
                )
            case "ReadBUID":
                sendUSBMuxResponse(
                    ["BUID": daemon.systemBUID],
                    tag: request.packet.tag,
                    context: context
                )
            case "SavePairRecord":
                if
                    let identifier =
                        request.dictionary["PairRecordID"] as? String,
                    let data =
                        request.dictionary["PairRecordData"] as? Data
                {
                    daemon.recordSavedPairingRecord(
                        identifier: identifier,
                        data: data,
                        deviceID:
                            request.dictionary.uint32("DeviceID")
                    )
                }
                sendUSBMuxResponse(
                    ["Number": daemon.savePairingRecordStatus],
                    tag: request.packet.tag,
                    context: context
                )
            case "DeletePairRecord":
                if
                    let identifier =
                        request.dictionary["PairRecordID"] as? String
                {
                    daemon.recordRemovedPairingRecord(
                        identifier: identifier
                    )
                }
                sendUSBMuxResponse(
                    ["Number": daemon.removePairingRecordStatus],
                    tag: request.packet.tag,
                    context: context
                )
            case "Connect":
                let port = daemon.normalizedPort(
                    from: request.dictionary["PortNumber"]
                )
                daemon.recordConnectedPort(port)
                sendUSBMuxResponse(
                    ["Number": 0],
                    tag: request.packet.tag,
                    context: context
                )
                switch port {
                case 62_078:
                    state = .lockdown
                case 1_234:
                    state = .afc
                case 2_345:
                    state = .installationProxy
                case 3_456:
                    state = .misagent
                case 4_567:
                    state = .heartbeat
                    sendPlistMessage(
                        ["Interval": 2],
                        context: context
                    )
                case 5_678:
                    state = .houseArrest
                default:
                    close(context: context)
                }
            default:
                sendUSBMuxResponse(
                    ["Number": 1],
                    tag: request.packet.tag,
                    context: context
                )
            }
            return true
        }

        private func processLockdownRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard let request = readPlistMessage() else {
                return false
            }
            switch request["Request"] as? String {
            case "StartSession":
                sendPlistMessage(
                    [
                        "Result": "Success",
                        "SessionID": "fake-session",
                        "EnableSessionSSL": daemon.secureLockdown,
                    ],
                    context: context
                )
            case "GetValue":
                let value: Any
                switch request["Key"] as? String {
                case "UniqueDeviceID":
                    value = "fake-device-1"
                case "DevicePublicKey":
                    value = daemon.devicePublicKey
                case "WiFiAddress":
                    value = daemon.wiFiMACAddress
                default:
                    value = [
                        "UniqueDeviceID": "fake-device-1",
                        "DeviceName": "Fake Phone",
                        "ProductType": "iPhone16,2",
                        "ProductVersion": "18.0",
                        "BuildVersion": "22A000",
                    ]
                }
                sendPlistMessage(
                    [
                        "Result": "Success",
                        "Value": value,
                    ],
                    context: context
                )
            case "Pair":
                sendPlistMessage(
                    daemon.nextPairingResponse(),
                    context: context
                )
            case "Unpair":
                if
                    let pairRecord =
                        request["PairRecord"] as? [String: Any],
                    let hostIdentifier =
                        pairRecord["HostID"] as? String
                {
                    daemon.recordUnpairedHostIdentifier(
                        hostIdentifier
                    )
                }
                sendPlistMessage(
                    daemon.unpairingResponse,
                    context: context
                )
            case "StartService":
                let service = request["Service"] as? String ?? ""
                if request["EscrowBag"] is Data {
                    daemon.recordServiceStartedWithEscrow(service)
                }
                let port: Int
                switch service {
                case LockdownServiceName.afc.rawValue:
                    port = 1_234
                case LockdownServiceName.installationProxy.rawValue:
                    port = 2_345
                case LockdownServiceName.misagent.rawValue:
                    port = 3_456
                case LockdownServiceName.heartbeat.rawValue:
                    port = 4_567
                case LockdownServiceName.houseArrest.rawValue:
                    port = 5_678
                default:
                    sendPlistMessage(
                        [
                            "Result": "Failure",
                            "Error": "UnknownService",
                        ],
                        context: context
                    )
                    return true
                }
                sendPlistMessage(
                    [
                        "Result": "Success",
                        "Port": port,
                        "EnableServiceSSL":
                            daemon.secureServices.contains(service),
                    ],
                    context: context
                )
            default:
                sendPlistMessage(
                    [
                        "Result": "Failure",
                        "Error": "UnhandledRequest",
                    ],
                    context: context
                )
            }
            return true
        }

        private func processAFCRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard let packet = readAFCPacket() else {
                return false
            }
            daemon.recordAFCOperation(packet.operation)
            switch packet.operation {
            case 13:
                send(
                    fakeAFCFileOpenResponse(
                        packetNumber: packet.packetNumber,
                        handle: 99
                    ),
                    context: context
                )
            case 20:
                send(
                    fakeAFCStatusResponse(
                        packetNumber: packet.packetNumber,
                        status: 0
                    ),
                    context: context
                )
                close(context: context)
            default:
                send(
                    fakeAFCStatusResponse(
                        packetNumber: packet.packetNumber,
                        status: 0
                    ),
                    context: context
                )
            }
            return true
        }

        private func processInstallationProxyRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard let request = readPlistMessage() else {
                return false
            }
            if let packagePath = request["PackagePath"] as? String {
                daemon.recordInstalledPackage(packagePath)
            }
            sendPlistMessage(
                ["Status": "Installing", "PercentComplete": 50],
                context: context
            )
            sendPlistMessage(
                ["Status": "Complete"],
                context: context
            )
            close(context: context)
            return true
        }

        private func processMISAgentRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard let request = readPlistMessage() else {
                return false
            }
            let messageType =
                request["MessageType"] as? String ?? ""
            daemon.recordMISAgentMessageType(messageType)
            if messageType == "CopyAll" || messageType == "Copy" {
                sendPlistMessage(
                    [
                        "Status": 0,
                        "Payload": [Data([9, 9, 9])],
                    ],
                    context: context
                )
            } else {
                sendPlistMessage(
                    ["Status": 0],
                    context: context
                )
            }
            close(context: context)
            return true
        }

        private func processHeartbeatRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard
                let request = readPlistMessage(),
                let command = request["Command"] as? String
            else {
                return false
            }
            daemon.recordHeartbeatReply(command)
            close(context: context)
            return true
        }

        private func processHouseArrestRequest(
            context: ChannelHandlerContext
        ) -> Bool {
            guard
                let request = readPlistMessage(),
                let command = request["Command"] as? String,
                let identifier = request["Identifier"] as? String
            else {
                return false
            }
            daemon.recordHouseArrestRequest(
                command: command,
                identifier: identifier
            )
            sendPlistMessage(
                ["Status": "Complete"],
                context: context
            )
            state = .afc
            return true
        }

        private func readUSBMuxRequest() -> (
            packet: USBMuxPacket,
            dictionary: [String: Any]
        )? {
            guard
                inbound.readableBytes >= USBMuxPacket.headerLength,
                let rawLength = inbound.getInteger(
                    at: inbound.readerIndex,
                    endianness: .little,
                    as: UInt32.self
                ),
                let length = Int(exactly: rawLength),
                length >= USBMuxPacket.headerLength,
                inbound.readableBytes >= length,
                let headerBytes = inbound.readBytes(
                    length: USBMuxPacket.headerLength
                ),
                let payloadBytes = inbound.readBytes(
                    length: length - USBMuxPacket.headerLength
                ),
                let packet = try? USBMuxPacket.decode(
                    header: Data(headerBytes),
                    payload: Data(payloadBytes)
                ),
                let dictionary = try? PropertyListCodec.decode(
                    packet.payload
                ) as? [String: Any]
            else {
                return nil
            }
            return (packet, dictionary)
        }

        private func readPlistMessage() -> [String: Any]? {
            guard
                inbound.readableBytes >= 4,
                let rawLength = inbound.getInteger(
                    at: inbound.readerIndex,
                    endianness: .big,
                    as: UInt32.self
                ),
                let length = Int(exactly: rawLength),
                inbound.readableBytes >= length + 4
            else {
                return nil
            }
            inbound.moveReaderIndex(forwardBy: 4)
            guard
                let payload = inbound.readBytes(length: length)
            else {
                return nil
            }
            return try? PropertyListCodec.decode(
                Data(payload)
            ) as? [String: Any]
        }

        private func readAFCPacket() -> FakeAFCPacket? {
            let start = inbound.readerIndex
            guard
                inbound.readableBytes >= 40,
                inbound.getBytes(at: start, length: 8) ==
                    Array("CFA6LPAA".utf8),
                let entireLength = inbound.getInteger(
                    at: start + 8,
                    endianness: .little,
                    as: UInt64.self
                ),
                entireLength >= 40,
                let length = Int(exactly: entireLength),
                inbound.readableBytes >= length,
                let packetNumber = inbound.getInteger(
                    at: start + 24,
                    endianness: .little,
                    as: UInt64.self
                ),
                let operation = inbound.getInteger(
                    at: start + 32,
                    endianness: .little,
                    as: UInt64.self
                )
            else {
                return nil
            }
            inbound.moveReaderIndex(forwardBy: length)
            return FakeAFCPacket(
                operation: operation,
                packetNumber: packetNumber
            )
        }

        private func sendUSBMuxResponse(
            _ dictionary: [String: Any],
            tag: UInt32,
            context: ChannelHandlerContext
        ) {
            guard
                let payload = try? PropertyListCodec.encode(dictionary),
                let packet = try? USBMuxPacket(
                    tag: tag,
                    payload: payload
                ).encoded()
            else {
                return
            }
            send(packet, context: context)
        }

        private func sendUSBMuxEvent(
            _ event: USBMuxDeviceEvent,
            context: ChannelHandlerContext
        ) {
            let dictionary: [String: Any]
            switch event {
            case .attached(let device):
                dictionary = [
                    "MessageType": "Attached",
                    "DeviceID": device.deviceID,
                    "Properties": [
                        "SerialNumber": device.serialNumber,
                        "ConnectionType":
                            device.properties["ConnectionType"] ??
                            "USB",
                    ],
                ]
            case .detached(let deviceID, let serialNumber):
                var detached: [String: Any] = [
                    "MessageType": "Detached",
                    "DeviceID": deviceID,
                ]
                if let serialNumber {
                    detached["SerialNumber"] = serialNumber
                }
                dictionary = detached
            }
            sendUSBMuxResponse(
                dictionary,
                tag: 0,
                context: context
            )
        }

        private func sendPlistMessage(
            _ dictionary: [String: Any],
            context: ChannelHandlerContext
        ) {
            guard
                let message = try? PropertyListMessageFramer.encode(
                    dictionary
                )
            else {
                return
            }
            send(message, context: context)
        }

        private func send(
            _ data: Data,
            context: ChannelHandlerContext
        ) {
            var buffer = context.channel.allocator.buffer(
                capacity: data.count
            )
            buffer.writeBytes(data)
            context.writeAndFlush(
                wrapOutboundOut(buffer),
                promise: nil
            )
        }

        private func close(context: ChannelHandlerContext) {
            state = .closed
            context.close(promise: nil)
        }
    }

    private func normalizedPort(from value: Any?) -> UInt16 {
        let raw = (value as? NSNumber)?.uint32Value ?? value as? UInt32 ?? 0
        return UInt16(truncatingIfNeeded: raw).bigEndian
    }

    private func recordConnectedPort(_ port: UInt16) {
        lock.lock()
        _connectedPorts.append(port)
        lock.unlock()
    }

    private func recordAFCOperation(_ operation: UInt64) {
        lock.lock()
        _afcOperations.append(operation)
        lock.unlock()
    }

    private func recordInstalledPackage(_ packagePath: String) {
        lock.lock()
        _installedPackagePaths.append(packagePath)
        lock.unlock()
    }

    private func recordMISAgentMessageType(_ messageType: String) {
        lock.lock()
        _misagentMessageTypes.append(messageType)
        lock.unlock()
    }

    private func recordServiceStartedWithEscrow(_ service: String) {
        lock.lock()
        _servicesStartedWithEscrow.append(service)
        lock.unlock()
    }

    private func recordHeartbeatReply(_ command: String) {
        lock.lock()
        _heartbeatReplies.append(command)
        lock.unlock()
    }

    private func recordHouseArrestRequest(command: String, identifier: String) {
        lock.lock()
        _houseArrestRequests.append([
            "Command": command,
            "Identifier": identifier,
        ])
        lock.unlock()
    }

    private func recordSavedPairingRecord(
        identifier: String,
        data: Data,
        deviceID: UInt32?
    ) {
        lock.lock()
        _savedPairingRecordIdentifier = identifier
        _savedPairingRecordData = data
        _savedPairingRecordDeviceID = deviceID
        lock.unlock()
    }

    /// Records the host pairing-record key requested for deletion.
    private func recordRemovedPairingRecord(identifier: String) {
        lock.lock()
        _removedPairingRecordIdentifier = identifier
        lock.unlock()
    }

    /// Records the host identity carried by a Lockdown Unpair request.
    private func recordUnpairedHostIdentifier(_ identifier: String) {
        lock.lock()
        _unpairedHostIdentifier = identifier
        lock.unlock()
    }

    private func nextPairingResponse() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        _pairingAttemptCount += 1
        guard !pairingResponses.isEmpty else {
            return [
                "Request": "Pair",
                "Error": "PairingDialogResponsePending",
            ]
        }
        return pairingResponses.removeFirst()
    }
}

private struct FakeAFCPacket {
    let operation: UInt64
    let packetNumber: UInt64
}

private func fakeAFCStatusResponse(packetNumber: UInt64, status: UInt64) -> Data {
    var payload = Data()
    payload.appendLittleEndian(status)
    return fakeAFCResponse(packetNumber: packetNumber, operation: 1, payload: payload)
}

private func fakeAFCFileOpenResponse(packetNumber: UInt64, handle: UInt64) -> Data {
    var payload = Data()
    payload.appendLittleEndian(handle)
    return fakeAFCResponse(packetNumber: packetNumber, operation: 14, payload: payload)
}

private func fakeAFCResponse(packetNumber: UInt64, operation: UInt64, payload: Data) -> Data {
    var data = Data("CFA6LPAA".utf8)
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(UInt64(40 + payload.count))
    data.appendLittleEndian(packetNumber)
    data.appendLittleEndian(operation)
    data.append(payload)
    return data
}
