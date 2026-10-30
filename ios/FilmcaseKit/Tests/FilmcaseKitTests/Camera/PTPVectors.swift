// Loads tests/fixtures/camera/ptp_vectors.json, the golden vectors shared with
// tests/js/ptp_packets.test.js and tests/unit/domain/camera/test_ptp_vectors.py.
// The fixture is read from the repo in place (never copied).

import Foundation
import Testing

struct CommandPacketVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let code: UInt16
    let tx_id: UInt32
    let params: [UInt32]
    let hex: String
    var testDescription: String { name }
}

struct DataPacketVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let code: UInt16
    let tx_id: UInt32
    let payload_hex: String
    let hex: String
    var testDescription: String { name }
}

struct PtpStringVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let value: String
    let hex: String
    var testDescription: String { name }
}

struct ResponseVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let hex: String
    let expected_code: UInt16
    let expected_params: [UInt32]
    var testDescription: String { name }
}

struct DeviceInfoVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let hex: String
    let expected_model: String
    let expected_supported_props: [UInt16]
    var testDescription: String { name }
}

struct PtpVectors: Decodable, Sendable {
    let command_packets: [CommandPacketVector]
    let data_packets: [DataPacketVector]
    let ptp_strings: [PtpStringVector]
    let responses: [ResponseVector]
    let device_info: [DeviceInfoVector]

    static let empty = PtpVectors(
        command_packets: [], data_packets: [], ptp_strings: [], responses: [], device_info: []
    )

    /// repo root / tests/fixtures/camera/ptp_vectors.json, resolved from this file's path.
    static func fixtureURL(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        // file -> Camera -> FilmcaseKitTests -> Tests -> FilmcaseKit -> ios -> repo root
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tests/fixtures/camera/ptp_vectors.json")
    }

    static func load() throws -> PtpVectors {
        try JSONDecoder().decode(PtpVectors.self, from: Data(contentsOf: fixtureURL()))
    }

    /// Never throws, so it can feed `@Test(arguments:)`; a load failure yields empty
    /// sections, which `PTPVectorsPresenceTests` turns into a test failure.
    static let shared: PtpVectors = (try? load()) ?? .empty
}

func bytes(fromHex hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
