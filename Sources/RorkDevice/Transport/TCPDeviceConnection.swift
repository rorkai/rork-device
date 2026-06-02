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
    private let condition = NSCondition()
    private var closed = false
    private var activeOperations = 0

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Opens a TCP connection to a host and port.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address to resolve.
    ///   - port: TCP port in host byte order.
    /// - Returns: An open connection that reads and writes exact byte buffers.
    public static func connect(to host: String, port: UInt16) async throws -> TCPDeviceConnection {
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
            try self.withOpenSocket { fd in
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    var sent = 0
                    while sent < data.count {
                        let result = systemSend(
                            fd,
                            base.advanced(by: sent),
                            data.count - sent,
                            socketSendFlags
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
    public func receive(exactly count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenSocket { fd in
                var data = Data(count: count)
                var received = 0
                try data.withUnsafeMutableBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    while received < count {
                        let result = systemRecv(
                            fd,
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
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        _ = systemShutdown(fileDescriptor)
        while activeOperations > 0 {
            condition.wait()
        }
        condition.unlock()

        _ = systemClose(fileDescriptor)
    }

    deinit {
        close()
    }

    /// Runs a socket operation while preventing concurrent descriptor closure.
    private func withOpenSocket<T>(_ body: (Int32) throws -> T) throws -> T {
        condition.lock()
        guard !closed else {
            condition.unlock()
            throw RorkDeviceError.transport("Connection is closed.")
        }
        activeOperations += 1
        let fd = fileDescriptor
        condition.unlock()

        defer {
            condition.lock()
            activeOperations -= 1
            if activeOperations == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }

        return try body(fd)
    }
}

/// Resolves and opens a TCP socket.
private func open(host: String, port: UInt16) throws -> TCPDeviceConnection {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: tcpSocketType,
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
            do {
                try disableSIGPIPE(for: fd)
                if systemConnect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return TCPDeviceConnection(fileDescriptor: fd)
                }
                lastError = lastErrnoMessage("connect")
            } catch {
                lastError = String(describing: error)
            }
            _ = systemClose(fd)
        }
        cursor = candidate.pointee.ai_next
    }

    throw RorkDeviceError.transport(lastError)
}

/// Platform-normalized TCP socket type.
private var tcpSocketType: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}

/// Formats the current POSIX `errno` for diagnostics.
private func lastErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}

/// Flags used for writes to avoid process-level SIGPIPE on closed sockets.
private var socketSendFlags: Int32 {
    #if canImport(Darwin)
    0
    #else
    Int32(MSG_NOSIGNAL)
    #endif
}

/// Configures Darwin sockets to report broken pipes through `send` errors.
private func disableSIGPIPE(for fd: Int32) throws {
    #if canImport(Darwin)
    var value: Int32 = 1
    let result = setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &value,
        socklen_t(MemoryLayout.size(ofValue: value))
    )
    guard result == 0 else {
        throw RorkDeviceError.transport(lastErrnoMessage("setsockopt(SO_NOSIGPIPE)"))
    }
    #else
    _ = fd
    #endif
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

/// Platform wrapper for `shutdown`.
@discardableResult
private func systemShutdown(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.shutdown(fd, SHUT_RDWR)
    #else
    return Glibc.shutdown(fd, Int32(SHUT_RDWR))
    #endif
}
