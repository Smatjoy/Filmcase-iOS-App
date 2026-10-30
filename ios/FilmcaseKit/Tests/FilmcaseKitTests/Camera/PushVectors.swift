// Swift half of the shared push sequences; mirrors tests/js/push_vectors.test.js and
// tests/unit/domain/camera/test_push_vectors.py. Loads tests/fixtures/camera/push_vectors.json
// in place (never copied or edited).

import Foundation
import Testing
@testable import FilmcaseKit

struct PushScenario: Decodable, Sendable, CustomTestStringConvertible {
    struct Device: Decodable, Sendable {
        var reject: [String: Int]?
        var reject_cursor: Int?
        var reject_slot_name: Int?
        var fail: [String]?
        var verify: Bool?
        var read_overrides: [String: Int]?
    }

    struct ExpectedError: Decodable, Sendable, Equatable {
        var type: String
        var failed_properties: [String]?
        var message: String?
    }

    let name: String
    let why: String
    let recipe: String
    let device: Device
    let writes: [[JSONValue]]
    let sleeps: [Double]
    let reads: [Int]
    let error: ExpectedError?
    var testDescription: String { name }
}

struct PushVectors: Decodable, Sendable {
    let settings: [String: JSONValue]
    let slot_index: Int
    let scenarios: [PushScenario]

    static func fixtureURL(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        // file -> Camera -> FilmcaseKitTests -> Tests -> FilmcaseKit -> ios -> repo root
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tests/fixtures/camera/push_vectors.json")
    }

    static func load() throws -> PushVectors {
        try JSONDecoder().decode(PushVectors.self, from: Data(contentsOf: fixtureURL()))
    }

    /// Never throws, so it can feed `@Test(arguments:)`; a load failure yields no scenarios,
    /// which the presence test turns into a failure.
    static let shared: PushVectors? = try? load()
    static var sharedScenarios: [PushScenario] { shared?.scenarios ?? [] }
}

/// What one scenario did, in the fixture's terms.
struct PushOutcome: Sendable {
    var writes: [[PTPPropertyValueKey]]
    var sleeps: [Double]
    var reads: [Int]
    var error: PushScenario.ExpectedError?
}

/// `[code, value]` for comparison with the fixture.
struct PTPPropertyValueKey: Equatable, Sendable {
    var int: Int?
    var string: String?
}

func key(_ json: JSONValue) -> PTPPropertyValueKey {
    switch json {
    case .int(let v): return PTPPropertyValueKey(int: v, string: nil)
    case .string(let s): return PTPPropertyValueKey(int: nil, string: s)
    default: return PTPPropertyValueKey(int: nil, string: "unexpected")
    }
}

/// Run one scenario against the current code and record what it did (`replay` in the JS test).
func replay(_ scenario: PushScenario, vectors: PushVectors) async throws -> PushOutcome {
    let enc = TestSupport.encodings
    let recipeVector = try #require(
        RecipePtpVectors.shared?.vectors.first { $0.name == scenario.recipe }, "unknown recipe \(scenario.recipe)"
    )
    let behaviour = scenario.device

    var reject: [UInt16: Int] = [:]
    for (name, rc) in behaviour.reject ?? [:] { reject[TestSupport.code(name)] = rc }
    if let rc = behaviour.reject_cursor { reject[UInt16(enc.propSlotCursor)] = rc }
    if let rc = behaviour.reject_slot_name { reject[UInt16(enc.propSlotName)] = rc }
    var setErrors: [UInt16: any Error] = [:]
    for name in behaviour.fail ?? [] {
        setErrors[TestSupport.code(name)] = CameraConnectionError("camera stopped answering")
    }
    var overrides: [UInt16: Int] = [:]
    for (name, value) in behaviour.read_overrides ?? [:] { overrides[TestSupport.code(name)] = value }

    let device = FakePTPDevice(intReadOverrides: overrides, setErrors: setErrors, setRejectionCodes: reject)
    var settings: [String: Any] = vectors.settings.mapValues(\.foundation)
    settings["CAMERA_VERIFY_WRITES"] = behaviour.verify ?? false
    let runtime = try TestSupport.runtime(device, settings)

    var error: PushScenario.ExpectedError?
    do {
        try await pushRecipeToCamera(device, recipe: recipeVector.recipe, slotIndex: vectors.slot_index, runtime: runtime)
    } catch let caught as RecipeWriteError {
        error = .init(type: "RecipeWriteError", failed_properties: caught.failedProperties, message: nil)
    } catch let caught as CameraConnectionError {
        error = .init(type: "CameraConnectionError", failed_properties: nil, message: caught.message)
    } catch let caught as CameraWriteError {
        error = .init(type: "CameraWriteError", failed_properties: nil, message: "code \(caught.code)")
    }

    let writes: [[PTPPropertyValueKey]] = await device.writes.map { write in
        switch write.value {
        case .int(let v): return [.init(int: Int(write.code), string: nil), .init(int: v, string: nil)]
        case .string(let s): return [.init(int: Int(write.code), string: nil), .init(int: nil, string: s)]
        }
    }
    return PushOutcome(
        writes: writes,
        sleeps: await device.sleeps.map { ($0 * 1_000_000).rounded() / 1_000_000 },
        reads: await device.reads.map(Int.init),
        error: error
    )
}

@Suite("Shared push vectors")
struct PushVectorsTests {
    @Test("fixture loads, has every section and at least 13 scenarios")
    func fixturePresent() throws {
        let data = try Data(contentsOf: PushVectors.fixtureURL())
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for section in ["settings", "slot_index", "scenarios"] {
            #expect(raw[section] != nil, "missing section \(section)")
        }
        let vectors = try PushVectors.load()
        #expect(vectors.scenarios.count >= 13)
        #expect(!vectors.settings.isEmpty)
        #expect(vectors.slot_index == 2)
    }

    @Test("writes the same sequence the Python does", arguments: PushVectors.sharedScenarios)
    func writesMatch(_ scenario: PushScenario) async throws {
        let vectors = try #require(PushVectors.shared)
        let outcome = try await replay(scenario, vectors: vectors)
        #expect(outcome.writes == scenario.writes.map { $0.map(key) }, Comment(rawValue: scenario.why))
    }

    @Test("pauses in the same places the Python does", arguments: PushVectors.sharedScenarios)
    func sleepsMatch(_ scenario: PushScenario) async throws {
        // The delays are distinct in this fixture, so this says which pause happened where.
        let vectors = try #require(PushVectors.shared)
        let outcome = try await replay(scenario, vectors: vectors)
        #expect(outcome.sleeps == scenario.sleeps, Comment(rawValue: scenario.why))
    }

    @Test("fails the same way the Python does", arguments: PushVectors.sharedScenarios)
    func errorMatches(_ scenario: PushScenario) async throws {
        let vectors = try #require(PushVectors.shared)
        let outcome = try await replay(scenario, vectors: vectors)
        #expect(outcome.error == scenario.error, Comment(rawValue: scenario.why))
    }

    @Test("reads back the same properties the Python does", arguments: PushVectors.sharedScenarios)
    func readsMatch(_ scenario: PushScenario) async throws {
        let vectors = try #require(PushVectors.shared)
        let outcome = try await replay(scenario, vectors: vectors)
        #expect(outcome.reads == scenario.reads, Comment(rawValue: scenario.why))
    }
}
