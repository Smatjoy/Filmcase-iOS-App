// Mirrors: the struct.pack/unpack "<" little-endian calls in
// src/domain/camera/ptp_usb_device.py (DataView little-endian accessors in the JS).

import Foundation

/// Read an unsigned 16-bit little-endian integer; throws if out of bounds.
public func readUInt16LE(_ data: [UInt8], _ offset: Int) throws -> UInt16 {
    try checkBounds(data, offset, 2)
    return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

/// Read an unsigned 32-bit little-endian integer; throws if out of bounds.
public func readUInt32LE(_ data: [UInt8], _ offset: Int) throws -> UInt32 {
    try checkBounds(data, offset, 4)
    var value: UInt32 = 0
    for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
    return value
}

/// Read a signed 32-bit little-endian integer (Python `"<i"`); throws if out of bounds.
public func readInt32LE(_ data: [UInt8], _ offset: Int) throws -> Int32 {
    Int32(bitPattern: try readUInt32LE(data, offset))
}

/// Little-endian bytes of a uint16.
public func packUInt16LE(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
}

/// Little-endian bytes of a uint32.
public func packUInt32LE(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
}

/// Little-endian bytes of a signed int32 (Python `struct.pack("<i", v)`).
public func packInt32LE(_ value: Int32) -> [UInt8] {
    packUInt32LE(UInt32(bitPattern: value))
}

private func checkBounds(_ data: [UInt8], _ offset: Int, _ needed: Int) throws {
    guard offset >= 0, offset + needed <= data.count else {
        throw PTPError.truncated(offset: offset, needed: needed, available: data.count)
    }
}
