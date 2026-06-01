import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX TCP implementation of `DeviceConnection`.
///
/// This connection is intentionally small and blocking internally. Public async
/// methods run socket work on detached tasks so service clients can use a
/// uniform async API without depending on Foundation networking APIs.
public final class TCPDeviceConnection: DeviceConnection {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Opens a TCP connection to a host and port.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address to resolve.
    ///   - port: TCP port in host byte order.
    /// - Returns: An open connection that reads and writes exact byte buffers.
    public static func connect(host: String, port: UInt16) async throws -> TCPDeviceConnection {
        try await Task.detached(priority: .userInitiated) {
            try open(host: host, port: port)
        }.value
    }

    /// Sends all bytes in `data`.
    ///
    /// The method loops until the complete buffer has been written or the
    /// underlying socket reports an error.
    public func send(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenSocket {
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    var sent = 0
                    while sent < data.count {
                        let result = systemSend(
                            self.fileDescriptor,
                            base.advanced(by: sent),
                            data.count - sent,
                            0
                        )
                        if result <= 0 {
                            throw RorkDeviceError.transport(lastErrnoMessage("send"))
                        }
                        sent += result
                    }
                }
            }
        }.value
    }

    /// Receives exactly `count` bytes unless the connection closes first.
    ///
    /// - Throws: `RorkDeviceError.transport` if the peer closes early or a
    ///   socket read fails.
    public func receive(count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenSocket {
                var data = Data(count: count)
                var received = 0
                try data.withUnsafeMutableBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    while received < count {
                        let result = systemRecv(
                            self.fileDescriptor,
                            base.advanced(by: received),
                            count - received,
                            0
                        )
                        if result == 0 {
                            throw RorkDeviceError.transport("Connection closed while reading \(count) bytes.")
                        }
                        if result < 0 {
                            throw RorkDeviceError.transport(lastErrnoMessage("recv"))
                        }
                        received += result
                    }
                }
                return data
            }
        }.value
    }

    /// Closes the socket. Calling this more than once is safe.
    public func close() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()

        if shouldClose {
            _ = systemClose(fileDescriptor)
        }
    }

    deinit {
        close()
    }

    /// Runs a socket operation after checking that the descriptor is open.
    private func withOpenSocket<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed {
            throw RorkDeviceError.transport("Connection is closed.")
        }
        return try body()
    }
}

/// Resolves and opens a TCP socket.
private func open(host: String, port: UInt16) throws -> TCPDeviceConnection {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let result else {
        throw RorkDeviceError.transport(String(cString: gai_strerror(status)))
    }
    defer { freeaddrinfo(result) }

    var cursor: UnsafeMutablePointer<addrinfo>? = result
    var lastError = "No address candidates."
    while let candidate = cursor {
        let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
        if fd >= 0 {
            if systemConnect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                return TCPDeviceConnection(fileDescriptor: fd)
            }
            lastError = lastErrnoMessage("connect")
            _ = systemClose(fd)
        }
        cursor = candidate.pointee.ai_next
    }

    throw RorkDeviceError.transport(lastError)
}

/// Formats the current POSIX `errno` for diagnostics.
private func lastErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}

/// Platform wrapper for `send`.
@discardableResult
private func systemSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buffer, length, flags)
    #else
    return Glibc.send(fd, buffer, length, flags)
    #endif
}

/// Platform wrapper for `recv`.
@discardableResult
private func systemRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.recv(fd, buffer, length, flags)
    #else
    return Glibc.recv(fd, buffer, length, flags)
    #endif
}

/// Platform wrapper for `connect`.
@discardableResult
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

/// Platform wrapper for `close`.
@discardableResult
private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
