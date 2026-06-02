import Foundation

#if canImport(Security)
import Security

/// Apple-platform secure-session backend for Lockdown and service connections.
///
/// This upgrader uses Security.framework's SecureTransport APIs because they can
/// wrap an existing byte stream through custom I/O callbacks. That is the shape
/// required by usbmux-forwarded device service connections.
public struct AppleSecureSessionUpgrader: SecureSessionUpgrader {
    /// Creates an Apple secure-session upgrader.
    public init() {}

    /// Performs a client-side TLS handshake using pairing-record credentials.
    public func upgrade(_ connection: DeviceConnection, pairingRecord: PairingRecord) async throws -> DeviceConnection {
        try await Task.detached(priority: .userInitiated) {
            let identity = try AppleSecureSessionIdentity(pairingRecord: pairingRecord)
            return try SecureTransportDeviceConnection(
                base: connection,
                identity: identity.identity,
                certificateChain: identity.certificateChain,
                trustedServerCertificateData: identity.trustedServerCertificateData
            )
        }.value
    }
}

/// TLS-wrapped `DeviceConnection` backed by SecureTransport.
final class SecureTransportDeviceConnection: DeviceConnection {
    private let base: DeviceConnection
    private let context: SSLContext
    private let callbackBox: SecureTransportCallbackBox
    private let callbackPointer: UnsafeMutableRawPointer
    private let trustedServerCertificateData: [Data]
    private let condition = NSCondition()
    private var closed = false
    private var activeOperations = 0
    private var serverTrustEvaluated = false

    init(
        base: DeviceConnection,
        identity: SecIdentity,
        certificateChain: [SecCertificate],
        trustedServerCertificateData: [Data]
    ) throws {
        self.base = base
        self.trustedServerCertificateData = trustedServerCertificateData
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw RorkDeviceError.secureSession("Could not create SSL context.")
        }
        self.context = context
        callbackBox = SecureTransportCallbackBox(base: base)
        callbackPointer = Unmanaged.passRetained(callbackBox).toOpaque()

        try checkSSL(SSLSetIOFuncs(context, secureTransportRead, secureTransportWrite), "SSLSetIOFuncs")
        try checkSSL(SSLSetConnection(context, callbackPointer), "SSLSetConnection")
        try configureProtocolBounds(context)
        try checkSSL(SSLSetSessionOption(context, .breakOnServerAuth, true), "SSLSetSessionOption(server auth)")

        let certificates = [identity] + certificateChain
        try checkSSL(SSLSetCertificate(context, certificates as CFArray), "SSLSetCertificate")
        try performHandshake()
    }

    deinit {
        close()
        Unmanaged<SecureTransportCallbackBox>.fromOpaque(callbackPointer).release()
    }

    /// Sends all bytes through the TLS session.
    func send(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenContext {
                try data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return
                    }
                    var sent = 0
                    while sent < data.count {
                        var processed = 0
                        let status = SSLWrite(
                            self.context,
                            baseAddress.advanced(by: sent),
                            data.count - sent,
                            &processed
                        )
                        if status == errSSLWouldBlock {
                            continue
                        }
                        if status != errSecSuccess {
                            throw RorkDeviceError.secureSession("SSLWrite failed with status \(status).")
                        }
                        guard processed > 0 else {
                            throw RorkDeviceError.secureSession("SSLWrite made no progress.")
                        }
                        sent += processed
                    }
                }
            }
        }.value
    }

    /// Receives exactly `count` decrypted bytes from the TLS session.
    func receive(exactly count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenContext {
                var data = Data(count: count)
                var received = 0
                try data.withUnsafeMutableBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return
                    }
                    while received < count {
                        var processed = 0
                        let status = SSLRead(
                            self.context,
                            baseAddress.advanced(by: received),
                            count - received,
                            &processed
                        )
                        if status == errSSLWouldBlock {
                            continue
                        }
                        if status != errSecSuccess {
                            throw RorkDeviceError.secureSession("SSLRead failed with status \(status).")
                        }
                        guard processed > 0 else {
                            throw RorkDeviceError.secureSession("SSLRead made no progress.")
                        }
                        received += processed
                    }
                }
                return data
            }
        }.value
    }

    /// Closes the TLS session and underlying connection.
    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        base.close()
        while activeOperations > 0 {
            condition.wait()
        }
        condition.unlock()

        _ = SSLClose(context)
    }

    /// Runs a TLS operation while the context is open.
    private func withOpenContext<T>(_ body: () throws -> T) throws -> T {
        condition.lock()
        guard !closed else {
            condition.unlock()
            throw RorkDeviceError.transport("Connection is closed.")
        }
        activeOperations += 1
        condition.unlock()

        defer {
            condition.lock()
            activeOperations -= 1
            if activeOperations == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }

        return try body()
    }

    /// Drives SecureTransport's handshake state machine to completion.
    private func performHandshake() throws {
        while true {
            let status = SSLHandshake(context)
            switch status {
            case errSecSuccess:
                return
            case secureTransportServerAuthCompleted:
                try evaluatePeerTrust()
                continue
            case errSSLWouldBlock:
                continue
            default:
                throw RorkDeviceError.secureSession("SSLHandshake failed with status \(status).")
            }
        }
    }

    /// Verifies the server certificate presented by the device.
    private func evaluatePeerTrust() throws {
        guard !serverTrustEvaluated else {
            return
        }

        var trust: SecTrust?
        try checkSSL(SSLCopyPeerTrust(context, &trust), "SSLCopyPeerTrust")
        guard let trust else {
            throw RorkDeviceError.secureSession("Device did not present server trust.")
        }

        // Lockdown pairing records pin the device certificate directly.
        // Platform trust evaluation can reject older pairing certificates for
        // legacy digest algorithms before the pinning decision is reached.
        let peerCertificateData = try peerLeafCertificateData(from: trust)
        guard trustedServerCertificateData.contains(peerCertificateData) else {
            throw RorkDeviceError.secureSession("Device server certificate did not match the pairing record.")
        }

        serverTrustEvaluated = true
    }
}

/// Callback context retained for SecureTransport I/O.
private final class SecureTransportCallbackBox {
    let base: DeviceConnection

    init(base: DeviceConnection) {
        self.base = base
    }
}

/// Swift imports SecureTransport's canonical peer-auth status, while the C
/// headers document the server-auth break as a deprecated macro alias.
private let secureTransportServerAuthCompleted = errSSLPeerAuthCompleted

/// Transfer box used to bridge async transport calls into callbacks.
private final class SecureTransportAsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// SecureTransport read callback backed by the underlying device connection.
private func secureTransportRead(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let requested = dataLength.pointee
    guard requested > 0 else {
        dataLength.pointee = 0
        return errSecSuccess
    }

    let box = Unmanaged<SecureTransportCallbackBox>
        .fromOpaque(UnsafeRawPointer(connection))
        .takeUnretainedValue()
    do {
        let bytes = try waitForSecureTransportIO {
            if let partialConnection = box.base as? PartialReceiveDeviceConnection {
                return try await partialConnection.receive(upTo: requested)
            }
            return try await box.base.receive(exactly: requested)
        }
        bytes.withUnsafeBytes { buffer in
            if let source = buffer.baseAddress {
                memcpy(data, source, bytes.count)
            }
        }
        dataLength.pointee = bytes.count
        return errSecSuccess
    } catch {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}

/// SecureTransport write callback backed by `DeviceConnection.send`.
private func secureTransportWrite(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let requested = dataLength.pointee
    guard requested > 0 else {
        dataLength.pointee = 0
        return errSecSuccess
    }

    let box = Unmanaged<SecureTransportCallbackBox>
        .fromOpaque(UnsafeRawPointer(connection))
        .takeUnretainedValue()
    let bytes = Data(bytes: data, count: requested)
    do {
        try waitForSecureTransportIO {
            try await box.base.send(bytes)
        }
        dataLength.pointee = requested
        return errSecSuccess
    } catch {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}

/// Blocks a SecureTransport callback until the async byte-stream operation ends.
private func waitForSecureTransportIO<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SecureTransportAsyncResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do {
            box.result = Result.success(try await operation())
        } catch {
            box.result = Result.failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.result else {
        throw RorkDeviceError.secureSession("SecureTransport callback did not complete.")
    }
    return try result.get()
}

/// Creates the client identity and optional chain from a pairing record.
private struct AppleSecureSessionIdentity {
    let identity: SecIdentity
    let certificateChain: [SecCertificate]
    let trustedServerCertificateData: [Data]

    init(pairingRecord: PairingRecord) throws {
        guard let deviceCertificate = pairingRecord.deviceCertificate else {
            throw RorkDeviceError.invalidPairingRecord("Missing DeviceCertificate.")
        }
        guard let hostCertificate = pairingRecord.hostCertificate else {
            throw RorkDeviceError.invalidPairingRecord("Missing HostCertificate.")
        }
        guard let hostPrivateKey = pairingRecord.hostPrivateKey else {
            throw RorkDeviceError.invalidPairingRecord("Missing HostPrivateKey.")
        }

        let certificate = try makeCertificate(hostCertificate, name: "HostCertificate")
        let privateKey = try makePrivateKey(hostPrivateKey, name: "HostPrivateKey")
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw RorkDeviceError.secureSession("HostCertificate does not match HostPrivateKey.")
        }
        self.identity = identity

        if let rootCertificate = pairingRecord.rootCertificate {
            certificateChain = [try makeCertificate(rootCertificate, name: "RootCertificate")]
        } else {
            certificateChain = []
        }

        let deviceCertificateDER = try derFromPEMOrRaw(deviceCertificate)
        _ = try makeCertificate(deviceCertificateDER, name: "DeviceCertificate")
        trustedServerCertificateData = [deviceCertificateDER]
    }
}

/// Returns the DER bytes for the peer leaf certificate presented by Lockdown.
private func peerLeafCertificateData(from trust: SecTrust) throws -> Data {
    guard let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leafCertificate = certificateChain.first else {
        throw RorkDeviceError.secureSession("Device did not present a server certificate.")
    }
    return SecCertificateCopyData(leafCertificate) as Data
}

/// Creates a `SecCertificate` from DER or PEM certificate data.
private func makeCertificate(_ data: Data, name: String) throws -> SecCertificate {
    let der = try derFromPEMOrRaw(data)
    guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
        throw RorkDeviceError.secureSession("Could not parse \(name).")
    }
    return certificate
}

/// Creates an RSA private key from DER or PEM key data.
private func makePrivateKey(_ data: Data, name: String) throws -> SecKey {
    let der = try unwrapPKCS8IfNeeded(derFromPEMOrRaw(data))
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(
        der as CFData,
        [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary,
        &error
    ) else {
        let message = error?.takeRetainedValue().localizedDescription ?? "Unknown key import error."
        throw RorkDeviceError.secureSession("Could not parse \(name): \(message)")
    }
    return key
}

/// Extracts DER bytes from PEM armor or returns raw DER unchanged.
private func derFromPEMOrRaw(_ data: Data) throws -> Data {
    guard let string = String(data: data, encoding: .utf8),
          let beginRange = string.range(of: "-----BEGIN "),
          let endOfHeader = string[beginRange.upperBound...].range(of: "-----") else {
        return data
    }

    let footerSearchStart = endOfHeader.upperBound
    guard let footerRange = string[footerSearchStart...].range(of: "-----END ") else {
        throw RorkDeviceError.secureSession("Invalid PEM block.")
    }

    let base64 = string[footerSearchStart..<footerRange.lowerBound]
        .filter { !$0.isWhitespace }
    guard let decoded = Data(base64Encoded: String(base64)) else {
        throw RorkDeviceError.secureSession("Invalid PEM base64.")
    }
    return decoded
}

/// Unwraps a PKCS#8 RSA private key into PKCS#1 when necessary.
private func unwrapPKCS8IfNeeded(_ data: Data) throws -> Data {
    var reader = DERReader(data)
    guard let top = try? reader.readSequence(), reader.isAtEnd else {
        return data
    }

    var sequence = top
    _ = try? sequence.readInteger()
    guard var algorithm = try? sequence.readSequence(),
          algorithm.containsOID([1, 2, 840, 113_549, 1, 1, 1]),
          let privateKey = try? sequence.readOctetString() else {
        return data
    }
    return privateKey
}

/// Minimal DER reader for unwrapping PKCS#8 RSA keys.
private struct DERReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readSequence() throws -> DERReader {
        DERReader(try read(tag: 0x30))
    }

    mutating func readInteger() throws -> Data {
        try read(tag: 0x02)
    }

    mutating func readOctetString() throws -> Data {
        try read(tag: 0x04)
    }

    mutating func containsOID(_ components: [Int]) -> Bool {
        let encoded = encodeOID(components)
        while offset < data.count {
            guard let value = try? readAny() else {
                return false
            }
            if value.tag == 0x06 && value.value == encoded {
                return true
            }
        }
        return false
    }

    private mutating func readAny() throws -> (tag: UInt8, value: Data) {
        guard offset < data.count else {
            throw RorkDeviceError.secureSession("Unexpected end of DER data.")
        }
        let tag = data[offset]
        offset += 1
        let length = try readLength()
        guard offset + length <= data.count else {
            throw RorkDeviceError.secureSession("Invalid DER length.")
        }
        let value = data[offset..<(offset + length)]
        offset += length
        return (tag, Data(value))
    }

    private mutating func read(tag expectedTag: UInt8) throws -> Data {
        let item = try readAny()
        guard item.tag == expectedTag else {
            throw RorkDeviceError.secureSession("Unexpected DER tag.")
        }
        return item.value
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else {
            throw RorkDeviceError.secureSession("Unexpected end of DER length.")
        }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= 4, offset + byteCount <= data.count else {
            throw RorkDeviceError.secureSession("Unsupported DER length.")
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }
}

/// Encodes a dotted ASN.1 OID for simple equality checks.
private func encodeOID(_ components: [Int]) -> Data {
    guard components.count >= 2 else {
        return Data()
    }
    var bytes = [UInt8(components[0] * 40 + components[1])]
    for component in components.dropFirst(2) {
        var value = component
        var stack = [UInt8(value & 0x7f)]
        value >>= 7
        while value > 0 {
            stack.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(contentsOf: stack.reversed())
    }
    return Data(bytes)
}

/// Applies broad protocol bounds for older Lockdown implementations.
///
/// TLS 1.0 compatibility is intentional here: Lockdown runs over a local
/// usbmux-forwarded channel and the server certificate is pinned to the pairing
/// record, so this is an old-device compatibility setting rather than a
/// public-network trust downgrade.
private func configureProtocolBounds(_ context: SSLContext) throws {
    _ = SSLSetProtocolVersionMin(context, .tlsProtocol1)
}

/// Converts non-success SecureTransport status values to structured errors.
private func checkSSL(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        throw RorkDeviceError.secureSession("\(operation) failed with status \(status).")
    }
}

#endif
