// Mirrors: _command_packet, _data_packet, _parse_response and the _PTP_* /
// _OC_* / _RC_* constants in src/domain/camera/ptp_usb_device.py and
// src/interfaces/static/js/camera/vendor/ptp_usb_device.js.

import Foundation

// PTP/USB packet types (PIMA 15740:2000 section 5.3.1)
public let ptpCommand: UInt16 = 0x0001
public let ptpData: UInt16 = 0x0002
public let ptpResponse: UInt16 = 0x0003

// Operation codes
public let ocGetDeviceInfo: UInt16 = 0x1001
public let ocOpenSession: UInt16 = 0x1002
public let ocCloseSession: UInt16 = 0x1003
public let ocGetDevicePropValue: UInt16 = 0x1015
public let ocSetDevicePropValue: UInt16 = 0x1016

// Response codes
public let rcOk: UInt16 = 0x2001
public let rcSessionAlready: UInt16 = 0x201E  // treat as OK

/// The container header: uint32 length, uint16 type, uint16 code, uint32 transaction id.
public let headerBytes = 12

/// A parsed PTP response: Python's `(code, params)` tuple.
public struct PTPResponse: Equatable, Sendable {
    public let code: UInt16
    public let params: [UInt32]
}

/// Build a PTP command container packet (no data payload).
public func commandPacket(code: UInt16, txId: UInt32, params: [UInt32] = []) -> [UInt8] {
    let length = UInt32(headerBytes + params.count * 4)
    var packet = packUInt32LE(length) + packUInt16LE(ptpCommand) + packUInt16LE(code) + packUInt32LE(txId)
    for param in params { packet += packUInt32LE(param) }
    return packet
}

/// Build a PTP data container packet.
public func dataPacket(code: UInt16, txId: UInt32, payload: [UInt8]) -> [UInt8] {
    let length = UInt32(headerBytes + payload.count)
    return packUInt32LE(length) + packUInt16LE(ptpData) + packUInt16LE(code) + packUInt32LE(txId) + payload
}

/// Parse a PTP response container. Throws `PTPError.responseTooShort` below 12 bytes.
public func parseResponse(_ raw: [UInt8]) throws -> PTPResponse {
    guard raw.count >= headerBytes else {
        throw PTPError.responseTooShort(byteCount: raw.count)
    }
    let length = Int(try readUInt32LE(raw, 0))
    let code = try readUInt16LE(raw, 6)
    let paramCount = (min(length, raw.count) - headerBytes) / 4
    var params: [UInt32] = []
    for i in 0..<max(paramCount, 0) {
        params.append(try readUInt32LE(raw, headerBytes + i * 4))
    }
    return PTPResponse(code: code, params: params)
}
