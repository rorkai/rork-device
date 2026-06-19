import Darwin
import Foundation
@testable import RorkDevice

final class FakeUSBMuxDaemon {
    let port: UInt16

    private let serverFD: Int32
    private let secureLockdown: Bool
    private let secureServices: Set<String>
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

    /// Device identifier from the most recent DeletePairRecord request.
    private var _removedPairingRecordIdentifier: String?

    /// Host identifier from the most recent Lockdown Unpair request.
    private var _unpairedHostIdentifier: String?
    private var pairingResponses: [[String: Any]]
    private var _pairingAttemptCount = 0

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
            "Request": "ValidatePair",
        ],
        keepListenOpenAfterEvents: Bool = false
    ) throws {
        self.secureLockdown = secureLockdown
        self.secureServices = secureServices
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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RorkDeviceError.transport("socket failed: \(String(cString: strerror(errno)))")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw RorkDeviceError.transport("bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw RorkDeviceError.transport("listen failed: \(String(cString: strerror(errno)))")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw RorkDeviceError.transport("getsockname failed: \(String(cString: strerror(errno)))")
        }
        serverFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
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
            close(serverFD)
        }
    }

    private func acceptLoop() {
        while !isStopped {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
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

    /// Blocks until the peer closes a held-open Listen connection.
    private func waitForListenPeerClose(_ fd: Int32) {
        var byte = UInt8(0)
        while true {
            let readCount = recv(fd, &byte, 1, 0)
            if readCount <= 0 {
                recordListenPeerClosed()
                return
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        defer { close(fd) }
        guard let request = readUSBMuxRequest(fd) else {
            return
        }

        switch request.dictionary["MessageType"] as? String {
        case "ListDevices":
            sendUSBMuxResponse([
                "DeviceList": [
                    [
                        "DeviceID": 1,
                        "Properties": [
                            "SerialNumber": "fake-device-1",
                            "ConnectionType": "USB",
                        ],
                    ],
                ],
            ], tag: request.packet.tag, to: fd)
        case "Listen":
            recordListenConnectionOpen()
            sendUSBMuxResponse(listenResponse, tag: request.packet.tag, to: fd)
            for event in deviceEvents {
                sendUSBMuxEvent(event, to: fd)
            }
            if keepListenOpenAfterEvents {
                waitForListenPeerClose(fd)
            }
        case "ReadPairRecord":
            guard let pairingRecordData else {
                sendUSBMuxResponse(
                    ["Number": 2],
                    tag: request.packet.tag,
                    to: fd
                )
                return
            }
            var response: [String: Any] = [
                "PairRecordData": pairingRecordData,
            ]
            if let pairingRecordStatus {
                response["Number"] = pairingRecordStatus
            }
            sendUSBMuxResponse(response, tag: request.packet.tag, to: fd)
        case "ReadBUID":
            sendUSBMuxResponse(
                ["BUID": systemBUID],
                tag: request.packet.tag,
                to: fd
            )
        case "SavePairRecord":
            if let identifier = request.dictionary["PairRecordID"] as? String,
               let data = request.dictionary["PairRecordData"] as? Data {
                recordSavedPairingRecord(identifier: identifier, data: data)
            }
            sendUSBMuxResponse(
                ["Number": savePairingRecordStatus],
                tag: request.packet.tag,
                to: fd
            )
        case "DeletePairRecord":
            if let identifier = request.dictionary["PairRecordID"] as? String {
                recordRemovedPairingRecord(identifier: identifier)
            }
            sendUSBMuxResponse(
                ["Number": removePairingRecordStatus],
                tag: request.packet.tag,
                to: fd
            )
        case "Connect":
            let port = normalizedPort(from: request.dictionary["PortNumber"])
            recordConnectedPort(port)
            sendUSBMuxResponse(["Number": 0], tag: request.packet.tag, to: fd)
            switch port {
            case 62078:
                handleLockdown(fd)
            case 1234:
                handleAFC(fd)
            case 2345:
                handleInstallationProxy(fd)
            case 3456:
                handleMISAgent(fd)
            case 4567:
                handleHeartbeat(fd)
            case 5678:
                handleHouseArrest(fd)
            default:
                return
            }
        default:
            sendUSBMuxResponse(["Number": 1], tag: request.packet.tag, to: fd)
        }
    }

    private func handleLockdown(_ fd: Int32) {
        while let request = readPlistMessage(fd) {
            switch request["Request"] as? String {
            case "StartSession":
                sendPlistMessage([
                    "Result": "Success",
                    "SessionID": "fake-session",
                    "EnableSessionSSL": secureLockdown,
                ], to: fd)
            case "GetValue":
                let value: Any
                switch request["Key"] as? String {
                case "DevicePublicKey":
                    value = devicePublicKey
                case "WiFiAddress":
                    value = wiFiMACAddress
                default:
                    value = [
                        "UniqueDeviceID": "fake-device-1",
                        "DeviceName": "Fake Phone",
                        "ProductType": "iPhone16,2",
                        "ProductVersion": "18.0",
                        "BuildVersion": "22A000",
                    ]
                }
                sendPlistMessage([
                    "Result": "Success",
                    "Value": value,
                ], to: fd)
            case "Pair":
                sendPlistMessage(nextPairingResponse(), to: fd)
            case "Unpair":
                if let pairRecord = request["PairRecord"] as? [String: Any],
                   let hostIdentifier = pairRecord["HostID"] as? String {
                    recordUnpairedHostIdentifier(hostIdentifier)
                }
                sendPlistMessage(unpairingResponse, to: fd)
            case "StartService":
                let service = request["Service"] as? String ?? ""
                if request["EscrowBag"] is Data {
                    recordServiceStartedWithEscrow(service)
                }
                let port: Int
                switch service {
                case LockdownServiceName.afc.rawValue:
                    port = 1234
                case LockdownServiceName.installationProxy.rawValue:
                    port = 2345
                case LockdownServiceName.misagent.rawValue:
                    port = 3456
                case LockdownServiceName.heartbeat.rawValue:
                    port = 4567
                case LockdownServiceName.houseArrest.rawValue:
                    port = 5678
                default:
                    sendPlistMessage(["Result": "Failure", "Error": "UnknownService"], to: fd)
                    continue
                }
                sendPlistMessage([
                    "Result": "Success",
                    "Port": port,
                    "EnableServiceSSL": secureServices.contains(service),
                ], to: fd)
            default:
                sendPlistMessage(["Result": "Failure", "Error": "UnhandledRequest"], to: fd)
            }
        }
    }

    private func handleAFC(_ fd: Int32) {
        while let packet = readAFCPacket(fd) {
            recordAFCOperation(packet.operation)
            switch packet.operation {
            case 13:
                sendAll(fakeAFCFileOpenResponse(packetNumber: packet.packetNumber, handle: 99), to: fd)
            case 20:
                sendAll(fakeAFCStatusResponse(packetNumber: packet.packetNumber, status: 0), to: fd)
                return
            default:
                sendAll(fakeAFCStatusResponse(packetNumber: packet.packetNumber, status: 0), to: fd)
            }
        }
    }

    private func handleInstallationProxy(_ fd: Int32) {
        guard let request = readPlistMessage(fd) else {
            return
        }
        if let packagePath = request["PackagePath"] as? String {
            recordInstalledPackage(packagePath)
        }
        sendPlistMessage(["Status": "Installing", "PercentComplete": 50], to: fd)
        sendPlistMessage(["Status": "Complete"], to: fd)
    }

    private func handleMISAgent(_ fd: Int32) {
        guard let request = readPlistMessage(fd) else {
            return
        }
        let messageType = request["MessageType"] as? String ?? ""
        recordMISAgentMessageType(messageType)
        if messageType == "CopyAll" || messageType == "Copy" {
            sendPlistMessage([
                "Status": 0,
                "Payload": [Data([9, 9, 9])],
            ], to: fd)
        } else {
            sendPlistMessage(["Status": 0], to: fd)
        }
    }

    private func handleHeartbeat(_ fd: Int32) {
        sendPlistMessage(["Interval": 2], to: fd)
        guard let request = readPlistMessage(fd),
              let command = request["Command"] as? String else {
            return
        }
        recordHeartbeatReply(command)
    }

    private func handleHouseArrest(_ fd: Int32) {
        guard let request = readPlistMessage(fd),
              let command = request["Command"] as? String,
              let identifier = request["Identifier"] as? String else {
            return
        }
        recordHouseArrestRequest(command: command, identifier: identifier)
        sendPlistMessage(["Status": "Complete"], to: fd)
        handleAFC(fd)
    }

    private func readUSBMuxRequest(_ fd: Int32) -> (packet: USBMuxPacket, dictionary: [String: Any])? {
        guard let header = readExact(fd, count: USBMuxPacket.headerLength),
              let length = try? Int(header.littleEndianInteger(at: 0, as: UInt32.self)),
              length >= USBMuxPacket.headerLength,
              let payload = readExact(fd, count: length - USBMuxPacket.headerLength),
              let packet = try? USBMuxPacket.decode(header: header, payload: payload),
              let dictionary = try? PropertyListCodec.decode(packet.payload) as? [String: Any] else {
            return nil
        }
        return (packet, dictionary)
    }

    private func readPlistMessage(_ fd: Int32) -> [String: Any]? {
        guard let lengthData = readExact(fd, count: 4),
              let length = try? Int(lengthData.bigEndianInteger(at: 0, as: UInt32.self)),
              let payload = readExact(fd, count: length) else {
            return nil
        }
        return try? PropertyListCodec.decode(payload) as? [String: Any]
    }

    private func sendUSBMuxResponse(_ dictionary: [String: Any], tag: UInt32, to fd: Int32) {
        guard let payload = try? PropertyListCodec.encode(dictionary),
              let packet = try? USBMuxPacket(tag: tag, payload: payload).encoded() else {
            return
        }
        sendAll(packet, to: fd)
    }

    private func sendUSBMuxEvent(_ event: USBMuxDeviceEvent, to fd: Int32) {
        let dictionary: [String: Any]
        switch event {
        case .attached(let device):
            dictionary = [
                "MessageType": "Attached",
                "DeviceID": device.deviceID,
                "Properties": [
                    "SerialNumber": device.serialNumber,
                    "ConnectionType": device.properties["ConnectionType"] ?? "USB",
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
        sendUSBMuxResponse(dictionary, tag: 0, to: fd)
    }

    private func sendPlistMessage(_ dictionary: [String: Any], to fd: Int32) {
        guard let message = try? PropertyListMessageFramer.encode(dictionary) else {
            return
        }
        sendAll(message, to: fd)
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

    private func recordSavedPairingRecord(identifier: String, data: Data) {
        lock.lock()
        _savedPairingRecordIdentifier = identifier
        _savedPairingRecordData = data
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

private func readAFCPacket(_ fd: Int32) -> FakeAFCPacket? {
    guard let header = readExact(fd, count: 40),
          header.prefix(8) == Data("CFA6LPAA".utf8),
          let entireLength = try? header.littleEndianInteger(at: 8, as: UInt64.self),
          entireLength >= 40 else {
        return nil
    }
    if entireLength > 40 {
        _ = readExact(fd, count: Int(entireLength - 40))
    }
    return FakeAFCPacket(
        operation: (try? header.littleEndianInteger(at: 32, as: UInt64.self)) ?? 0,
        packetNumber: (try? header.littleEndianInteger(at: 24, as: UInt64.self)) ?? 0
    )
}

private func readExact(_ fd: Int32, count: Int) -> Data? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else {
            return true
        }
        while offset < count {
            let result = recv(fd, base.advanced(by: offset), count - offset, 0)
            if result <= 0 {
                return false
            }
            offset += result
        }
        return true
    }
    return success ? Data(bytes) : nil
}

private func sendAll(_ data: Data, to fd: Int32) {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else {
            return
        }
        var offset = 0
        while offset < data.count {
            let sent = send(fd, base.advanced(by: offset), data.count - offset, 0)
            if sent <= 0 {
                return
            }
            offset += sent
        }
    }
}
