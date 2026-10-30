// Swift half of the shared PTP wire-format golden vectors; mirrors
// tests/js/ptp_packets.test.js and tests/unit/domain/camera/test_ptp_vectors.py.

import Foundation
import Testing
@testable import FilmcaseKit

@Suite("PTP vectors fixture")
struct PTPVectorsPresenceTests {
    @Test("fixture loads and every section is non-empty")
    func sectionsPresent() throws {
        let vectors = try PtpVectors.load()
        #expect(!vectors.command_packets.isEmpty)
        #expect(!vectors.data_packets.isEmpty)
        #expect(!vectors.ptp_strings.isEmpty)
        #expect(!vectors.responses.isEmpty)
        #expect(!vectors.device_info.isEmpty)
    }
}

@Suite("PTP framing")
struct PTPFramingTests {
    @Test("commandPacket matches frozen bytes", arguments: PtpVectors.shared.command_packets)
    func commandPacketMatches(_ v: CommandPacketVector) {
        #expect(hex(commandPacket(code: v.code, txId: v.tx_id, params: v.params)) == v.hex)
    }

    @Test("dataPacket matches frozen bytes", arguments: PtpVectors.shared.data_packets)
    func dataPacketMatches(_ v: DataPacketVector) {
        #expect(hex(dataPacket(code: v.code, txId: v.tx_id, payload: bytes(fromHex: v.payload_hex))) == v.hex)
    }

    @Test("encodePtpString matches frozen bytes", arguments: PtpVectors.shared.ptp_strings)
    func encodeMatches(_ v: PtpStringVector) throws {
        #expect(hex(try encodePtpString(v.value)) == v.hex)
    }

    @Test("decodePtpString round trips", arguments: PtpVectors.shared.ptp_strings)
    func decodeRoundTrips(_ v: PtpStringVector) throws {
        let encoded = bytes(fromHex: v.hex)
        let result = try decodePtpString(encoded, 0)
        #expect(result.value == v.value)
        #expect(result.offset == encoded.count)
    }

    @Test("parseResponse yields frozen code and params", arguments: PtpVectors.shared.responses)
    func parseResponseMatches(_ v: ResponseVector) throws {
        let response = try parseResponse(bytes(fromHex: v.hex))
        #expect(response.code == v.expected_code)
        #expect(response.params == v.expected_params)
    }

    @Test("parseDeviceInfoModel finds the model", arguments: PtpVectors.shared.device_info)
    func modelMatches(_ v: DeviceInfoVector) throws {
        #expect(try parseDeviceInfoModel(bytes(fromHex: v.hex)) == v.expected_model)
    }

    @Test("parseDeviceInfoSupportedProps finds the properties", arguments: PtpVectors.shared.device_info)
    func supportedPropsMatch(_ v: DeviceInfoVector) throws {
        #expect(try parseDeviceInfoSupportedProps(bytes(fromHex: v.hex)) == v.expected_supported_props)
    }
}

@Suite("PTP helpers and error paths")
struct PTPHelperTests {
    @Test func decodePastEndReturnsEmpty() throws {
        let r = try decodePtpString([1, 2], 5)
        #expect(r.value == "")
        #expect(r.offset == 5)
    }

    @Test func decodeZeroLengthConsumesOneByte() throws {
        let r = try decodePtpString([0, 0xaa], 0)
        #expect(r.value == "")
        #expect(r.offset == 1)
    }

    @Test func decodeTruncatedStringThrows() {
        #expect(throws: PTPError.self) { try decodePtpString([3, 0x41, 0x00], 0) }
    }

    @Test func parseResponseTruncatedThrows() {
        #expect(throws: PTPError.responseTooShort(byteCount: 3)) { try parseResponse([1, 2, 3]) }
    }

    @Test func skipArraySkipsCountAndEntries() throws {
        #expect(try skipPtpUint16Array([2, 0, 0, 0, 0x11, 0x11, 0x22, 0x22, 0xff], 0) == 8)
        #expect(try skipPtpUint16Array([0, 0, 0, 0, 0xff], 0) == 4)
        #expect(try skipPtpUint16Array([2, 0], 0) == 0)
    }

    @Test func skipStringReturnsOffsetPastString() throws {
        let data = try encodePtpString("Hi")
        #expect(try skipPtpString(data, 0) == data.count)
    }

    @Test func deviceInfoOffsetsPointAtPropsAndManufacturer() throws {
        let v = try #require(PtpVectors.shared.device_info.first { $0.name == "x_s10" })
        let data = bytes(fromHex: v.hex)
        let offsets = try deviceInfoOffsets(data)
        #expect(try readUInt32LE(data, offsets.propsOffset) == 4)
        #expect(try decodePtpString(data, offsets.manufacturerOffset).value == "FUJIFILM")
    }

    @Test func littleEndianHelpers() throws {
        #expect(packInt32LE(-40) == [0xd8, 0xff, 0xff, 0xff])
        #expect(try readInt32LE([0xd8, 0xff, 0xff, 0xff], 0) == -40)
        #expect(try readUInt16LE([0x04, 0x00], 0) == 4)
        #expect(throws: PTPError.self) { try readUInt32LE([1, 2, 3], 0) }
    }

    @Test func encodeTooLongStringThrows() {
        #expect(throws: PTPError.stringTooLong(characterCount: 256)) {
            try encodePtpString(String(repeating: "x", count: 255))
        }
    }
}
