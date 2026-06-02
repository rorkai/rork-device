import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix-domain socket implementation of `DeviceConnection`.
///
/// This is the default transport used to reach the local usbmux daemon. Like
/// `TCPDeviceConnection`, socket operations are performed on detached tasks so
/// higher-level protocol clients can use one async byte-stream interface.
public final class UnixDomainSocketConnection: DeviceConnection, PartialReceiveDeviceConnection {
    private let fileDescriptor: Int32
    private let condition = NSCondition()
    private var closed = false
    private var activeOperations = 0

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Opens a Unix-domain socket connection.
    ///
    /// - Parameter path: Filesystem path to the socket, usually
    ///   `/var/run/usbmuxd`.
    /// - Returns: An open byte-stream connection.
    public static func connect(toSocketAt path: String) async throws -> UnixDomainSocketConnection {
        try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, unixSocketType, 0)
            guard fd >= 0 else {
                throw RorkDeviceError.transport(lastUnixErrnoMessage("socket"))
            }

            do {
                try disableUnixSIGPIPE(for: fd)

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
                guard path.utf8.count < maxPathLength else {
                    throw RorkDeviceError.invalidInput("Unix socket path is too long: \(path)")
                }

                _ = path.withCString { source in
                    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                        tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                            strncpy(destination, source, maxPathLength - 1)
                        }
                    }
                }

                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        systemUnixConnect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else {
                    throw RorkDeviceError.transport(lastUnixErrnoMessage("connect"))
                }

                return UnixDomainSocketConnection(fileDescriptor: fd)
            } catch {
                _ = systemUnixClose(fd)
                throw error
            }
        }.value
    }

    /// Sends all bytes in `data`.
    ///
    /// The method returns only after the full buffer has been written.
    public func send(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenSocket { fd in
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    var sent = 0
                    while sent < data.count {
                        let result = systemUnixSend(
                            fd,
                            base.advanced(by: sent),
                            data.count - sent,
                            unixSocketSendFlags
                        )
                        if result <= 0 {
                            throw RorkDeviceError.transport(lastUnixErrnoMessage("send"))
                        }
                        sent += result
                    }
                }
            }
        }.value
    }

    /// Receives exactly `count` bytes unless the peer closes the connection.
    ///
    /// - Throws: `RorkDeviceError.transport` if the daemon closes early or the
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
                        let result = systemUnixRecv(
                            fd,
                            base.advanced(by: received),
                            count - received,
                            0
                        )
                        if result == 0 {
                            throw RorkDeviceError.transport("Connection closed while reading \(count) bytes.")
                        }
                        if result < 0 {
                            throw RorkDeviceError.transport(lastUnixErrnoMessage("recv"))
                        }
                        received += result
                    }
                }
                return data
            }
        }.value
    }

    /// Receives one socket read containing at least one byte and at most `count`.
    func receive(upTo count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.withOpenSocket { fd in
                guard count > 0 else {
                    return Data()
                }

                var data = Data(count: count)
                let received = try data.withUnsafeMutableBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return 0
                    }

                    let result = systemUnixRecv(fd, base, count, 0)
                    if result == 0 {
                        throw RorkDeviceError.transport("Connection closed while reading up to \(count) bytes.")
                    }
                    if result < 0 {
                        throw RorkDeviceError.transport(lastUnixErrnoMessage("recv"))
                    }
                    return result
                }
                data.removeSubrange(received..<data.count)
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
        _ = systemUnixShutdown(fileDescriptor)
        while activeOperations > 0 {
            condition.wait()
        }
        condition.unlock()

        _ = systemUnixClose(fileDescriptor)
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

/// Platform-normalized Unix socket type.
private var unixSocketType: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}

/// Formats the current POSIX `errno` for Unix-socket diagnostics.
private func lastUnixErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}

/// Flags used for writes to avoid process-level SIGPIPE on closed sockets.
private var unixSocketSendFlags: Int32 {
    #if canImport(Darwin)
    0
    #else
    Int32(MSG_NOSIGNAL)
    #endif
}

/// Configures Darwin sockets to report broken pipes through `send` errors.
private func disableUnixSIGPIPE(for fd: Int32) throws {
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
        throw RorkDeviceError.transport(lastUnixErrnoMessage("setsockopt(SO_NOSIGPIPE)"))
    }
    #else
    _ = fd
    #endif
}

/// Platform wrapper for `send`.
@discardableResult
private func systemUnixSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buffer, length, flags)
    #else
    return Glibc.send(fd, buffer, length, flags)
    #endif
}

/// Platform wrapper for `recv`.
@discardableResult
private func systemUnixRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.recv(fd, buffer, length, flags)
    #else
    return Glibc.recv(fd, buffer, length, flags)
    #endif
}

/// Platform wrapper for `connect`.
@discardableResult
private func systemUnixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

/// Platform wrapper for `close`.
@discardableResult
private func systemUnixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

/// Platform wrapper for `shutdown`.
@discardableResult
private func systemUnixShutdown(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.shutdown(fd, SHUT_RDWR)
    #else
    return Glibc.shutdown(fd, Int32(SHUT_RDWR))
    #endif
}
