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
        let pair = try SocketPair()
        defer { pair.closeRight() }
        let connection = TCPDeviceConnection(fileDescriptor: pair.left)

        try pair.write("abc")

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    func testUnixConnectionReceiveUpToReturnsAvailableBytesWithoutWaitingForFullRequest() async throws {
        let pair = try SocketPair()
        defer { pair.closeRight() }
        let connection = UnixDomainSocketConnection(fileDescriptor: pair.left)

        try pair.write("abc")

        let data = try await connection.receive(upTo: 1024)

        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }
}

private struct SocketPair {
    let left: Int32
    let right: Int32

    init() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard systemSocketPair(&sockets) == 0 else {
            throw RorkDeviceError.transport(lastSocketPairErrnoMessage("socketpair"))
        }
        left = sockets[0]
        right = sockets[1]
    }

    func write(_ string: String) throws {
        let data = Data(string.utf8)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            let sent = systemSocketPairSend(right, baseAddress, data.count, 0)
            guard sent == data.count else {
                throw RorkDeviceError.transport(lastSocketPairErrnoMessage("send"))
            }
        }
    }

    func closeRight() {
        _ = systemSocketPairClose(right)
    }
}

@discardableResult
private func systemSocketPair(_ sockets: UnsafeMutablePointer<Int32>) -> Int32 {
    #if canImport(Darwin)
    return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)
    #else
    return Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, sockets)
    #endif
}

@discardableResult
private func systemSocketPairSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buffer, length, flags)
    #else
    return Glibc.send(fd, buffer, length, flags)
    #endif
}

@discardableResult
private func systemSocketPairClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func lastSocketPairErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}
