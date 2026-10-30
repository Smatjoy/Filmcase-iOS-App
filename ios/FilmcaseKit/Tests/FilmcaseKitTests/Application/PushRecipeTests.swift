// Mirrors tests/js/push_recipe.test.js (pushRecipeToCamera), plus withCamera from
// send_to_camera.js.

import Foundation
import Testing
@testable import FilmcaseKit

private let rejected = 0x2005

private func push(
    _ device: FakePTPDevice, recipe: Recipe? = nil, slotIndex: Int = 2, _ overrides: [String: Any] = [:]
) async throws {
    let recipe = try recipe ?? TestSupport.makeRecipe()
    try await pushRecipeToCamera(
        device, recipe: recipe, slotIndex: slotIndex, runtime: TestSupport.runtime(device, overrides))
}

/// Codes written, in order, excluding the cursor.
private func propertyWrites(_ device: FakePTPDevice) async -> [UInt16] {
    await device.writes.map(\.code).filter { $0 != TestSupport.propSlotCursor }
}

private func expectRecipeWriteError(_ failed: [String], _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected RecipeWriteError")
    } catch let error as RecipeWriteError {
        #expect(error.failedProperties == failed)
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Suite("pushRecipeToCamera")
struct PushRecipeTests {
    @Test func pointsAtTheSlotBeforeWritingAnything() async throws {
        let device = FakePTPDevice()
        try await push(device, slotIndex: 3)
        #expect(await device.events.first == .setUInt16(TestSupport.propSlotCursor, 3))
    }

    @Test func writesTheSlotNameBeforeTheProperties() async throws {
        let device = FakePTPDevice()
        try await push(device)
        #expect(await propertyWrites(device).first == TestSupport.propSlotName)
    }

    @Test func writesEveryPropertyTheConversionProduced() async throws {
        let device = FakePTPDevice()
        try await push(device)
        #expect(await propertyWrites(device).count == 16)
    }

    @Test func writesInTheServersOrder() async throws {
        let device = FakePTPDevice()
        try await push(device)
        let written = await propertyWrites(device)
        let expected = TestSupport.encodings.writeOrder.map { TestSupport.code($0) }.filter(written.contains)
        #expect(Array(written.dropFirst()) == expected)
    }

    @Test func writesTheColourTemperatureBeforeTheTwoShifts() async throws {
        let device = FakePTPDevice()
        try await push(device, recipe: TestSupport.makeRecipe(["white_balance": .string("6500K"), "white_balance_red": .int(-2)]))
        let order = await propertyWrites(device)
        let temperature = try #require(order.firstIndex(of: TestSupport.code("WhiteBalanceColorTemperature")))
        let red = try #require(order.firstIndex(of: TestSupport.code("WhiteBalanceRed")))
        #expect(temperature < red)
    }

    @Test func storesTheNameAsAString() async throws {
        let device = FakePTPDevice()
        try await push(device, recipe: TestSupport.makeRecipe(["name": .string("Kodak Portra")]))
        #expect(try await device.getString(TestSupport.propSlotName) == "Kodak Portra")
    }

    @Test func leavesEveryValueInTheSlot() async throws {
        let device = FakePTPDevice()
        try await push(device, recipe: TestSupport.makeRecipe(["sharpness": .string("+2")]))
        #expect(try await device.getInt(TestSupport.code("Sharpness")) == 20)
    }

    @Test func resolvesWithVerificationSwitchedOn() async throws {
        let device = FakePTPDevice()
        try await push(device, ["CAMERA_VERIFY_WRITES": true])
    }
}

@Suite("push timing")
struct PushTimingTests {
    @Test func pausesBeforeAndAfterEveryWrite() async throws {
        let device = FakePTPDevice()
        try await push(device, ["CAMERA_PRE_WRITE_DELAY_S": 0.05, "CAMERA_POST_WRITE_DELAY_S": 0.2])
        let sleeps = await device.sleeps
        let writes = await propertyWrites(device).count
        // One pause after the cursor, then a pre/post pair per write.
        #expect(sleeps.count == 1 + writes * 2)
        #expect(sleeps[0] == 0.05)
        #expect(Array(sleeps[1...2]) == [0.05, 0.2])
    }

    @Test func stillPausesAfterARefusedWrite() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.code("FilmSimulation"): rejected])
        await #expect(throws: RecipeWriteError.self) {
            try await push(device, ["CAMERA_POST_WRITE_DELAY_S": 0.2])
        }
        let posts = await device.sleeps.filter { $0 == 0.2 }.count
        #expect(posts == (await propertyWrites(device)).count)
    }
}

@Suite("a camera that refuses properties")
struct RefusedPropertyTests {
    @Test func carriesOnWritingTheRest() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.code("FilmSimulation"): rejected])
        await expectRecipeWriteError(["FilmSimulation"]) { try await push(device) }
        #expect(await propertyWrites(device).contains(TestSupport.code("Definition")))
    }

    @Test func namesEveryPropertyThatDidNotTake() async throws {
        let device = FakePTPDevice(setRejectionCodes: [
            TestSupport.code("FilmSimulation"): rejected, TestSupport.code("Sharpness"): rejected,
        ])
        await expectRecipeWriteError(["FilmSimulation", "Sharpness"]) { try await push(device) }
    }

    @Test func reportsARefusedSlotNameByName() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.propSlotName: rejected])
        await expectRecipeWriteError(["SlotName"]) { try await push(device) }
    }
}

@Suite("a camera that stops answering")
struct VanishedCameraTests {
    @Test func abandonsTheSequence() async throws {
        let device = FakePTPDevice(setErrors: [TestSupport.code("FilmSimulation"): CameraConnectionError("unplugged")])
        await #expect(throws: CameraConnectionError.self) { try await push(device) }
        #expect(await !propertyWrites(device).contains(TestSupport.code("Definition")))
    }

    @Test func refusesThePushWhenTheCursorWillNotMove() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.propSlotCursor: rejected])
        do {
            try await push(device)
            Issue.record("expected CameraConnectionError")
        } catch let error as CameraConnectionError {
            #expect(error.message.contains("slot cursor"))
        }
        #expect(await propertyWrites(device).isEmpty)
    }
}

@Suite("an invalid recipe")
struct InvalidRecipeTests {
    @Test func neverReachesTheCameraAndLeavesTheSlotAlone() async throws {
        let device = FakePTPDevice()
        let recipe = try TestSupport.makeRecipe(["film_simulation": .string("Velvia 100F")])
        await #expect(throws: (any Error).self) { try await push(device, recipe: recipe) }
        #expect(await device.writes.map(\.code) == [TestSupport.propSlotCursor])
    }

    @Test func rejectsAnInvalidNumericField() async throws {
        let device = FakePTPDevice()
        let recipe = try TestSupport.makeRecipe(["color": .string("1.5")])
        await #expect(throws: (any Error).self) { try await push(device, recipe: recipe) }
        #expect(await propertyWrites(device).isEmpty)
    }
}

@Suite("push verification")
struct PushVerificationTests {
    let verify: [String: Any] = ["CAMERA_VERIFY_WRITES": true]

    @Test func isSkippedUnlessSwitchedOn() async throws {
        let device = FakePTPDevice()
        try await push(device)
        #expect(await device.reads.isEmpty)
    }

    @Test func readsBackEveryPropertyWhenSwitchedOn() async throws {
        let device = FakePTPDevice()
        try await push(device, verify)
        #expect(await !device.reads.isEmpty)
    }

    @Test func doesNotReadBackGrainWrittenAsTheSentinel() async throws {
        let device = FakePTPDevice()
        let recipe = try TestSupport.makeRecipe(["grain_roughness": .string("Off"), "grain_size": .null])
        try await push(device, recipe: recipe, verify)
        #expect(await !device.reads.contains(TestSupport.code("GrainEffect")))
    }

    @Test func readsBackGrainThatWasNotTheSentinel() async throws {
        let device = FakePTPDevice()
        let recipe = try TestSupport.makeRecipe(["grain_roughness": .string("Weak"), "grain_size": .string("Small")])
        try await push(device, recipe: recipe, verify)
        #expect(await device.reads.contains(TestSupport.code("GrainEffect")))
    }

    @Test func reportsAPropertyThatDidNotStick() async throws {
        let device = FakePTPDevice(intReadOverrides: [TestSupport.code("Sharpness"): 999])
        await expectRecipeWriteError(["Sharpness"]) { try await push(device, verify) }
    }

    @Test func doesNotReportARefusedPropertyTwice() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.code("Sharpness"): rejected])
        await expectRecipeWriteError(["Sharpness"]) { try await push(device, verify) }
    }
}

@Suite("withCamera")
struct WithCameraTests {
    @Test func connectsRunsAndDisconnects() async throws {
        let device = FakePTPDevice()
        let result = try await withCamera(device) { _ in 42 }
        #expect(result == 42)
        #expect(await device.events == [.connect, .disconnect])
    }

    @Test func disconnectsEvenWhenTheWorkFails() async throws {
        let device = FakePTPDevice()
        await #expect(throws: CameraConnectionError.self) {
            try await withCamera(device) { _ -> Int in throw CameraConnectionError("boom") }
        }
        #expect(await device.events == [.connect, .disconnect])
    }
}
