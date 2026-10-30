// Mirrors: _device_info_offsets, _parse_device_info_model and
// _parse_device_info_supported_props in src/domain/camera/ptp_usb_device.py and
// src/interfaces/static/js/camera/vendor/ptp_usb_device.js.

import Foundation

/// Byte offsets found by walking a GetDeviceInfo payload.
public struct DeviceInfoOffsets: Equatable, Sendable {
    public let propsOffset: Int
    public let manufacturerOffset: Int
}

/// Walk a GetDeviceInfo payload (including the 12-byte data-container header).
///
/// DeviceInfo layout (PIMA 15740:2000 section 5.5.1):
///     uint16 StandardVersion, uint32 VendorExtensionID, uint16 VendorExtensionVersion,
///     string VendorExtensionDesc, uint16 FunctionalMode, array16 OperationsSupported,
///     array16 EventsSupported, array16 DevicePropertiesSupported (propsOffset),
///     array16 CaptureFormats, array16 ImageFormats, string Manufacturer
///     (manufacturerOffset), string Model, ...
public func deviceInfoOffsets(_ data: [UInt8]) throws -> DeviceInfoOffsets {
    var off = headerBytes
    off += 2 + 4 + 2
    off = try skipPtpString(data, off)
    off += 2
    off = try skipPtpUint16Array(data, off)
    off = try skipPtpUint16Array(data, off)
    let propsOffset = off
    off = try skipPtpUint16Array(data, off)
    off = try skipPtpUint16Array(data, off)
    off = try skipPtpUint16Array(data, off)
    return DeviceInfoOffsets(propsOffset: propsOffset, manufacturerOffset: off)
}

/// Extract the Model string from a GetDeviceInfo payload.
public func parseDeviceInfoModel(_ data: [UInt8]) throws -> String {
    let offsets = try deviceInfoOffsets(data)
    let off = try skipPtpString(data, offsets.manufacturerOffset)
    return try decodePtpString(data, off).value
}

/// Extract DevicePropertiesSupported codes from a GetDeviceInfo payload.
public func parseDeviceInfoSupportedProps(_ data: [UInt8]) throws -> [UInt16] {
    let offsets = try deviceInfoOffsets(data)
    let propsOffset = offsets.propsOffset
    if propsOffset + 4 > data.count {
        return []
    }
    let count = Int(try readUInt32LE(data, propsOffset))
    let off = propsOffset + 4
    if count == 0 || off + count * 2 > data.count {
        return []
    }
    return try (0..<count).map { try readUInt16LE(data, off + $0 * 2) }
}
