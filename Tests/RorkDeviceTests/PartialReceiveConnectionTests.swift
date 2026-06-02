import Foundation
import XCTest
@testable import RorkDevice

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class PartialReceiveConnectionTests: XCTestCase {
    func testTCPConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let server = try TCPDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await TCPDeviceConnection.connect(to: "127.0.0.1", port: server.port)
        defer { connection.close() }

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    func testUnixConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let server = try UnixDataServer(data: "abc")
        defer { server.stop() }

        let connection = try await UnixDomainSocketConnection.connect(toSocketAt: server.path)
        defer { connection.close() }

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }
}

private final class TCPDataServer {
    let port: UInt16

    private let fileDescriptor: Int32
    private let data: Data
    private let lock = NSLock()
    private var stopped = false

    init(data string: String) throws {
        data = Data(string.utf8)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport(lastTestErrnoMessage("socket"))
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport(lastTestErrnoMessage("bind"))
        }
        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport(lastTestErrnoMessage("listen"))
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw RorkDeviceError.transport(lastTestErrnoMessage("getsockname"))
        }

        fileDescriptor = socketFD
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptAndSend()
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
            close(fileDescriptor)
        }
    }

    private func acceptAndSend() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        defer { close(clientFD) }
        sendAll(data, to: clientFD)
    }
}

private final class UnixDataServer {
    let path: String

    private let fileDescriptor: Int32
    private let data: Data
    private let lock = NSLock()
    private var stopped = false

    init(data string: String) throws {
        data = Data(string.utf8)
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rork-device-\(UUID().uuidString).sock")
            .path

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RorkDeviceError.transport(lastTestErrnoMessage("socket"))
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

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw RorkDeviceError.transport(lastTestErrnoMessage("bind"))
            }
            guard listen(socketFD, 1) == 0 else {
                throw RorkDeviceError.transport(lastTestErrnoMessage("listen"))
            }

            fileDescriptor = socketFD

            Thread.detachNewThread { [weak self] in
                self?.acceptAndSend()
            }
        } catch {
            close(socketFD)
            unlink(path)
            throw error
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
            close(fileDescriptor)
            unlink(path)
        }
    }

    private func acceptAndSend() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else {
            return
        }
        defer { close(clientFD) }
        sendAll(data, to: clientFD)
    }
}

private func sendAll(_ data: Data, to fileDescriptor: Int32) {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }

        var sent = 0
        while sent < data.count {
            let result = send(fileDescriptor, baseAddress.advanced(by: sent), data.count - sent, 0)
            guard result > 0 else {
                return
            }
            sent += result
        }
    }
}

private func lastTestErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}
