// Swift half of the recipe golden vectors; mirrors tests/js/queries.test.js,
// tests/js/validation.test.js and tests/unit/domain/camera/test_recipe_ptp_vectors.py.

import Foundation
import Testing
@testable import FilmcaseKit

@Suite("Recipe vectors fixture")
struct RecipeVectorsPresenceTests {
    @Test("fixture loads and every section is non-empty")
    func sectionsPresent() throws {
        let fixture = try RecipePtpVectors.load()
        #expect(fixture.vectors.count >= 10)
        #expect(fixture.validation_vectors.count >= 40)
        #expect(!fixture.encodings.customSlotCodes.isEmpty)
        #expect(!fixture.encodings.writeOrder.isEmpty)
        #expect(!fixture.encodings.nrToPtp.isEmpty)
        #expect(!fixture.encodings.filmSimulationToPtp.isEmpty)
    }
}

@Suite("Recipe to PTP values")
struct RecipePTPValuesTests {
    let encodings = RecipePtpVectors.shared?.encodings

    @Test("matches frozen items", arguments: RecipePtpVectors.sharedVectors)
    func matchesFrozenItems(_ v: RecipeItemVector) throws {
        let encodings = try #require(encodings)
        let values = try recipeToPtpValues(v.recipe, encodings: encodings)
        let items = ptpValueItems(values, encodings: encodings).map { [Int($0.code), $0.value] }
        #expect(items == v.expected_items, "\(v.why)")
    }

    @Test("colour temperature precedes the white balance shifts")
    func kelvinBeforeShifts() throws {
        let encodings = try #require(encodings)
        let fixture = try #require(RecipePtpVectors.shared)
        let recipe = try fixture.recipe(overrides: [
            "white_balance": .string("6500K"), "white_balance_red": .int(-2),
        ])
        let codes = ptpValueItems(try recipeToPtpValues(recipe, encodings: encodings), encodings: encodings).map(\.code)
        let temp = try #require(codes.firstIndex(of: UInt16(encodings.customSlotCodes["WhiteBalanceColorTemperature"]!)))
        let red = try #require(codes.firstIndex(of: UInt16(encodings.customSlotCodes["WhiteBalanceRed"]!)))
        #expect(temp < red)
    }

    @Test("an invalid recipe is rejected before conversion")
    func invalidThrows() throws {
        let encodings = try #require(encodings)
        let fixture = try #require(RecipePtpVectors.shared)
        let recipe = try fixture.recipe(overrides: ["film_simulation": .string("Velvia 100F")])
        #expect(throws: RecipeValidationError(field: "film_simulation", value: "'Velvia 100F'")) {
            try recipeToPtpValues(recipe, encodings: encodings)
        }
    }

    @Test("custom slot count comes from the served table; unknown models have none")
    func slotCount() throws {
        let encodings = try #require(encodings)
        #expect(customSlotCount(cameraName: "X-T50", encodings: encodings) == 7)
        #expect(customSlotCount(cameraName: "X-S10", encodings: encodings) == 4)
        #expect(customSlotCount(cameraName: "Nikon Z6", encodings: encodings) == 0)
    }
}

@Suite("Recipe validation")
struct RecipeValidationTests {
    @Test("agrees with the Python: accept/reject table", arguments: RecipePtpVectors.sharedValidation)
    func agreesWithPython(_ v: ValidationVector) throws {
        let fixture = try #require(RecipePtpVectors.shared)
        let recipe = try fixture.recipe(overrides: v.overrides)
        let outcome: String
        do {
            try validateRecipeForCamera(recipe, encodings: fixture.encodings)
            outcome = "ok"
        } catch let error as RecipeValidationError {
            outcome = "reject:\(error.field)"
        }
        #expect(outcome == v.expected)
    }

    @Test("error message names the field and value like Python")
    func errorMessage() {
        let error = RecipeValidationError(field: "grain_roughness", value: "('Weak', None)")
        #expect(error.description == "Invalid value for field 'grain_roughness': ('Weak', None)")
    }
}

@Suite("Camera profiles")
struct CameraProfileTests {
    @Test("unknown and known models share the per-property profile; xt50 equals it")
    func fallback() throws {
        let encodings = try #require(RecipePtpVectors.shared).encodings
        let base = CameraProfile.perProperty(encodings: encodings)
        #expect(getProfile(cameraName: "X-T50", encodings: encodings) == base)
        #expect(getProfile(cameraName: "Unheard Of 9000", encodings: encodings) == base)
        #expect(CameraProfile.xt50(encodings: encodings) == base)
        #expect(base.interface == .perProperty)
        #expect(base.supportedHighIsoNrValues == Set(-4...4))
        #expect(base.supportedFilmSimulations.contains("Reala Ace"))
    }

    @Test("validation is relative to the profile")
    func profileRelative() throws {
        let fixture = try #require(RecipePtpVectors.shared)
        var profile = CameraProfile.perProperty(encodings: fixture.encodings)
        profile.supportedFilmSimulations.remove("Classic Chrome")
        let recipe = try fixture.recipe(overrides: [:])
        #expect(throws: RecipeValidationError.self) {
            try validateRecipeForProfile(recipe, profile: profile)
        }
        try validateRecipeForCamera(recipe, encodings: fixture.encodings)
    }
}

@Suite("Client config decoding")
struct ClientConfigTests {
    @Test("encodings decode with integer NR keys")
    func nrKeys() throws {
        let encodings = try #require(RecipePtpVectors.shared).encodings
        #expect(encodings.nrToPtp[-4] == 32768)
        #expect(encodings.nrToPtp[4] == 20480)
        #expect(encodings.grainOffSentinel == 1)
        #expect(encodings.recipeNameMaxLen == 25)
    }

    @Test("encodings round trip through encode and decode")
    func roundTrip() throws {
        let encodings = try #require(RecipePtpVectors.shared).encodings
        let again = try JSONDecoder().decode(ClientEncodings.self, from: JSONEncoder().encode(encodings))
        #expect(again == encodings)
    }

    @Test("full client config decodes settings and encodings")
    func fullConfig() throws {
        let encodings = try #require(RecipePtpVectors.shared).encodings
        let encodingsJSON = try JSONEncoder().encode(encodings)
        let settings = """
        {"CAMERA_TRANSPORT":"browser","CAMERA_VERIFY_WRITES":true,"CAMERA_POST_READ_DELAY_S":0.05,
         "CAMERA_PRE_WRITE_DELAY_S":0.1,"CAMERA_POST_WRITE_DELAY_S":0.2,"CAMERA_POST_CURSOR_DELAY_S":0.3,
         "CAMERA_INTER_SLOT_DELAY_S":1.5,"CAMERA_MAX_RETRIES":3,"CAMERA_RETRY_BACKOFF_S":0.5,
         "CAMERA_USB_TIMEOUT_MS":5000}
        """
        let body = "{\"settings\":\(settings),\"encodings\":\(String(decoding: encodingsJSON, as: UTF8.self))}"
        let config = try JSONDecoder().decode(ClientConfig.self, from: Data(body.utf8))
        #expect(config.settings.cameraInterSlotDelayS == 1.5)
        #expect(config.settings.cameraMaxRetries == 3)
        #expect(config.encodings == encodings)
    }
}
