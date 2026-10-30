// Mirrors: ClientCameraSettings / ClientCameraEncodings in src/domain/camera/queries.py
// and the JS consumer vendor/client_config.js. Decodes /api/v1/camera/client-config.json
// (and the `encodings` section of tests/fixtures/camera/recipe_ptp_vectors.json, which
// has the same shape). Encodings are DATA passed in, never tables in Swift (ADR 016).

import Foundation

/// The property codes and value tables needed to write a recipe to a slot.
public struct ClientEncodings: Codable, Equatable, Sendable {
    public var vendorId: Int
    public var propPing: Int
    public var propSlotCursor: Int
    public var propSlotName: Int
    public var recipeNameMaxLen: Int
    public var customSlotCodes: [String: Int]
    public var writeOrder: [String]
    public var filmSimulationToPtp: [String: Int]
    public var whiteBalanceToPtp: [String: Int]
    public var drangeModeToPtp: [String: Int]
    public var drPriorityToPtp: [String: Int]
    /// roughness -> size -> value. Its "Off" entry is read-side only; write `grainOffSentinel`.
    public var grainToPtp: [String: [String: Int]]
    public var grainOffSentinel: Int
    public var cceToPtp: [String: Int]
    public var cfxToPtp: [String: Int]
    /// Keyed by domain value (-4...+4). JSON serves the keys as strings; converted on decode.
    public var nrToPtp: [Int: Int]
    public var cameraCustomSlotCounts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case vendorId = "vendor_id"
        case propPing = "prop_ping"
        case propSlotCursor = "prop_slot_cursor"
        case propSlotName = "prop_slot_name"
        case recipeNameMaxLen = "recipe_name_max_len"
        case customSlotCodes = "custom_slot_codes"
        case writeOrder = "write_order"
        case filmSimulationToPtp = "film_simulation_to_ptp"
        case whiteBalanceToPtp = "white_balance_to_ptp"
        case drangeModeToPtp = "drange_mode_to_ptp"
        case drPriorityToPtp = "dr_priority_to_ptp"
        case grainToPtp = "grain_to_ptp"
        case grainOffSentinel = "grain_off_sentinel"
        case cceToPtp = "cce_to_ptp"
        case cfxToPtp = "cfx_to_ptp"
        case nrToPtp = "nr_to_ptp"
        case cameraCustomSlotCounts = "camera_custom_slot_counts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendorId = try c.decode(Int.self, forKey: .vendorId)
        propPing = try c.decode(Int.self, forKey: .propPing)
        propSlotCursor = try c.decode(Int.self, forKey: .propSlotCursor)
        propSlotName = try c.decode(Int.self, forKey: .propSlotName)
        recipeNameMaxLen = try c.decode(Int.self, forKey: .recipeNameMaxLen)
        customSlotCodes = try c.decode([String: Int].self, forKey: .customSlotCodes)
        writeOrder = try c.decode([String].self, forKey: .writeOrder)
        filmSimulationToPtp = try c.decode([String: Int].self, forKey: .filmSimulationToPtp)
        whiteBalanceToPtp = try c.decode([String: Int].self, forKey: .whiteBalanceToPtp)
        drangeModeToPtp = try c.decode([String: Int].self, forKey: .drangeModeToPtp)
        drPriorityToPtp = try c.decode([String: Int].self, forKey: .drPriorityToPtp)
        grainToPtp = try c.decode([String: [String: Int]].self, forKey: .grainToPtp)
        grainOffSentinel = try c.decode(Int.self, forKey: .grainOffSentinel)
        cceToPtp = try c.decode([String: Int].self, forKey: .cceToPtp)
        cfxToPtp = try c.decode([String: Int].self, forKey: .cfxToPtp)
        let nr = try c.decode([String: Int].self, forKey: .nrToPtp)
        var nrByDomain: [Int: Int] = [:]
        for (key, value) in nr {
            guard let domain = Int(key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nrToPtp, in: c, debugDescription: "nr_to_ptp key is not an integer: \(key)"
                )
            }
            nrByDomain[domain] = value
        }
        nrToPtp = nrByDomain
        cameraCustomSlotCounts = try c.decode([String: Int].self, forKey: .cameraCustomSlotCounts)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendorId, forKey: .vendorId)
        try c.encode(propPing, forKey: .propPing)
        try c.encode(propSlotCursor, forKey: .propSlotCursor)
        try c.encode(propSlotName, forKey: .propSlotName)
        try c.encode(recipeNameMaxLen, forKey: .recipeNameMaxLen)
        try c.encode(customSlotCodes, forKey: .customSlotCodes)
        try c.encode(writeOrder, forKey: .writeOrder)
        try c.encode(filmSimulationToPtp, forKey: .filmSimulationToPtp)
        try c.encode(whiteBalanceToPtp, forKey: .whiteBalanceToPtp)
        try c.encode(drangeModeToPtp, forKey: .drangeModeToPtp)
        try c.encode(drPriorityToPtp, forKey: .drPriorityToPtp)
        try c.encode(grainToPtp, forKey: .grainToPtp)
        try c.encode(grainOffSentinel, forKey: .grainOffSentinel)
        try c.encode(cceToPtp, forKey: .cceToPtp)
        try c.encode(cfxToPtp, forKey: .cfxToPtp)
        let nrByString = Dictionary(uniqueKeysWithValues: nrToPtp.map { (String($0.key), $0.value) })
        try c.encode(nrByString, forKey: .nrToPtp)
        try c.encode(cameraCustomSlotCounts, forKey: .cameraCustomSlotCounts)
    }
}

/// The timing and retry settings both transports must agree on (keys are the Django
/// setting names verbatim, as in `ClientCameraSettings`).
public struct ClientSettings: Codable, Equatable, Sendable {
    public var cameraTransport: String
    public var cameraVerifyWrites: Bool
    public var cameraPostReadDelayS: Double
    public var cameraPreWriteDelayS: Double
    public var cameraPostWriteDelayS: Double
    public var cameraPostCursorDelayS: Double
    public var cameraInterSlotDelayS: Double
    public var cameraMaxRetries: Int
    public var cameraRetryBackoffS: Double
    public var cameraUsbTimeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case cameraTransport = "CAMERA_TRANSPORT"
        case cameraVerifyWrites = "CAMERA_VERIFY_WRITES"
        case cameraPostReadDelayS = "CAMERA_POST_READ_DELAY_S"
        case cameraPreWriteDelayS = "CAMERA_PRE_WRITE_DELAY_S"
        case cameraPostWriteDelayS = "CAMERA_POST_WRITE_DELAY_S"
        case cameraPostCursorDelayS = "CAMERA_POST_CURSOR_DELAY_S"
        case cameraInterSlotDelayS = "CAMERA_INTER_SLOT_DELAY_S"
        case cameraMaxRetries = "CAMERA_MAX_RETRIES"
        case cameraRetryBackoffS = "CAMERA_RETRY_BACKOFF_S"
        case cameraUsbTimeoutMs = "CAMERA_USB_TIMEOUT_MS"
    }
}

/// The whole `/camera/client-config.json` body.
public struct ClientConfig: Codable, Equatable, Sendable {
    public var settings: ClientSettings
    public var encodings: ClientEncodings
}
