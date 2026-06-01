import Foundation

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var copy = value.bigEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    func bigEndianInteger<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) throws -> T {
        try integer(at: offset, as: T.self).bigEndian
    }

    func littleEndianInteger<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) throws -> T {
        try integer(at: offset, as: T.self).littleEndian
    }

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
