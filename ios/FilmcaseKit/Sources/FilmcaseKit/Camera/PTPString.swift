// Mirrors: _decode_ptp_string, _encode_ptp_string, _skip_ptp_string and
// _skip_ptp_uint16_array in src/domain/camera/ptp_usb_device.py and
// src/interfaces/static/js/camera/vendor/ptp_usb_device.js.
// PTP strings: uint8 numChars + numChars x uint16 UCS-2 LE, NUL included.

import Foundation

/// Decode a PTP string starting at `offset`. Returns the string and the new offset.
public func decodePtpString(_ data: [UInt8], _ offset: Int) throws -> (value: String, offset: Int) {
    if offset >= data.count {
        return ("", offset)
    }
    let numChars = Int(data[offset])
    var off = offset + 1
    if numChars == 0 {
        return ("", off)
    }
    var units: [UInt16] = []
    for i in 0..<numChars {
        units.append(try readUInt16LE(data, off + i * 2))
    }
    off += numChars * 2
    // The last unit is the NUL terminator; any other NUL is dropped too (as the Python does).
    let kept = units.dropLast().filter { $0 != 0 }
    return (String(decoding: kept, as: UTF16.self), off)
}

/// Encode a string as a PTP string, NUL terminator included in the count.
/// The empty string is a single zero byte.
public func encodePtpString(_ value: String) throws -> [UInt8] {
    if value.isEmpty {
        return [0]
    }
    let units = Array(value.utf16) + [0]
    guard units.count <= 255 else {
        throw PTPError.stringTooLong(characterCount: units.count)
    }
    var out: [UInt8] = [UInt8(units.count)]
    for unit in units { out += packUInt16LE(unit) }
    return out
}

/// Skip a PTP string and return the new offset.
public func skipPtpString(_ data: [UInt8], _ offset: Int) throws -> Int {
    try decodePtpString(data, offset).offset
}

/// Skip a PTP uint16 array (uint32 count + count x uint16).
public func skipPtpUint16Array(_ data: [UInt8], _ offset: Int) throws -> Int {
    if offset + 4 > data.count {
        return offset
    }
    let count = Int(try readUInt32LE(data, offset))
    return offset + 4 + count * 2
}
