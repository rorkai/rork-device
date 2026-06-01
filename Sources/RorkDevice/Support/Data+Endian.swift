import Foundation

extension Data {
    /// Appends an integer in network byte order.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var copy = value.bigEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    /// Appends an integer in little-endian wire order.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    /// Reads an integer stored in network byte order.
    func bigEndianInteger<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) throws -> T {
        try integer(at: offset, as: T.self).bigEndian
    }

    /// Reads an integer stored in little-endian wire order.
    func littleEndianInteger<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) throws -> T {
        try integer(at: offset, as: T.self).littleEndian
    }

    /// Performs a bounds-checked unaligned integer load.
    private func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) throws -> T {
        let end = offset + MemoryLayout<T>.size
        guard offset >= 0, end <= count else {
            throw RorkDeviceError.protocolViolation("Packet is too short for \(T.self) at offset \(offset).")
        }

        return self[offset..<end].withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: T.self)
        }
    }
}
