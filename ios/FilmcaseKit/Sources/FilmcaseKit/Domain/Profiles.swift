// Mirrors: src/domain/camera/profiles.py (ADR 021). The JS client has no profile object;
// there the served encodings are the profile, so the value sets here are derived from the
// served `ClientEncodings` exactly as the Python derives them from its constants.

import Foundation

/// The slot-access mechanism a camera model exposes.
public enum CameraInterface: String, Equatable, Sendable {
    /// The custom-slot PTP property interface (X-S10, X-T3+).
    case perProperty = "per_property"
}

/// What one camera model can accept, plus which strategy drives it.
public struct CameraProfile: Equatable, Sendable {
    public var interface: CameraInterface
    public var recipeNameMaxLen: Int
    public var supportedFilmSimulations: Set<String>
    public var supportedWhiteBalanceModes: Set<String>
    public var supportedDynamicRanges: Set<String>
    public var supportedDrPriorities: Set<String>
    public var supportedColorChromeEffects: Set<String>
    public var supportedColorChromeFxBlues: Set<String>
    public var supportedGrainRoughnesses: Set<String>
    /// Sizes allowed when roughness is Off differ from those when it is Weak/Strong.
    public var grainSizesWhenOff: Set<String>
    public var grainSizesWhenOn: Set<String>
    public var supportedHighIsoNrValues: Set<Int>

    /// `PER_PROPERTY_PROFILE`: every value the custom-slot interface accepts, built from
    /// the served encodings. The grain sets are hardcoded in the Python and here alike.
    public static func perProperty(encodings: ClientEncodings) -> CameraProfile {
        CameraProfile(
            interface: .perProperty,
            recipeNameMaxLen: encodings.recipeNameMaxLen,
            supportedFilmSimulations: Set(encodings.filmSimulationToPtp.keys),
            supportedWhiteBalanceModes: Set(encodings.whiteBalanceToPtp.keys),
            supportedDynamicRanges: Set(encodings.drangeModeToPtp.keys),
            supportedDrPriorities: Set(encodings.drPriorityToPtp.keys),
            supportedColorChromeEffects: Set(encodings.cceToPtp.keys),
            supportedColorChromeFxBlues: Set(encodings.cfxToPtp.keys),
            supportedGrainRoughnesses: ["Off", "Weak", "Strong"],
            grainSizesWhenOff: ["Off", "Small", "Large"],
            grainSizesWhenOn: ["Small", "Large"],
            supportedHighIsoNrValues: Set(encodings.nrToPtp.keys)
        )
    }

    /// X-T50 (X-Trans V, 7 custom slots). The Python has no X-T50-specific profile: the
    /// per-property profile already lists all 20 film simulations (including Nostalgic
    /// Negative and Reala Ace) and every other value set, and
    /// `camera_custom_slot_counts["X-T50"]` is 7. Nothing X-T50-specific can be derived
    /// without invention, so this equals the per-property profile.
    public static func xt50(encodings: ClientEncodings) -> CameraProfile {
        perProperty(encodings: encodings)
    }
}

/// `get_profile`: the capability profile for a camera model. Every model, known or not,
/// resolves to the per-property profile (ADR 021: unknown models fall back rather than
/// being refused).
public func getProfile(cameraName: String, encodings: ClientEncodings) -> CameraProfile {
    CameraProfile.perProperty(encodings: encodings)
}
