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
public final class UnixDomainSocketConnection: DeviceConnection {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Opens a Unix-domain socket connection.
    ///
    /// - Parameter path: Filesystem path to the socket, usually
    ///   `/var/run/usbmuxd`.
    /// - Returns: An open byte-stream connection.
    public static func connect(path: String) async throws -> UnixDomainSocketConnection {
        try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw RorkDeviceError.transport(lastUnixErrnoMessage("socket"))
            }

            do {
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
            try self.withOpenSocket {
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }

                    var sent = 0
                    while sent < data.count {
                        let result = systemUnixSend(
                            self.fileDescriptor,
                            base.advanced(by: sent),
                            data.count - sent,
                            0
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
                        let result = systemUnixRecv(
                            self.fileDescriptor,
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

    /// Closes the socket. Calling this more than once is safe.
    public func close() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()

        if shouldClose {
            _ = systemUnixClose(fileDescriptor)
        }
    }

    deinit {
        close()
    }

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

private func lastUnixErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}

@discardableResult
private func systemUnixSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buffer, length, flags)
    #else
    return Glibc.send(fd, buffer, length, flags)
    #endif
}

@discardableResult
private func systemUnixRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.recv(fd, buffer, length, flags)
    #else
    return Glibc.recv(fd, buffer, length, flags)
    #endif
}

@discardableResult
private func systemUnixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

@discardableResult
private func systemUnixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
