// Mirrors tests/js/operations.test.js and the getStrategy cases of tests/js/strategies.test.js.

import Foundation
import Testing
@testable import FilmcaseKit

private let rejected = 0x2005

@Suite("setPropWithRetry")
struct SetPropWithRetryTests {
    let film = TestSupport.code("FilmSimulation")

    @Test func writesThroughOnFirstAttempt() async throws {
        let device = FakePTPDevice()
        try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        #expect(await device.writes.map(\.code) == [film])
        #expect(await device.writes.map(\.value) == [.int(11)])
    }

    @Test func dispatchesStringsToTheStringSetter() async throws {
        let device = FakePTPDevice()
        try await setPropWithRetry(
            device, code: TestSupport.propSlotName, value: .string("Kodak Portra"), runtime: TestSupport.runtime(device))
        #expect(try await device.getString(TestSupport.propSlotName) == "Kodak Portra")
        #expect(await device.events.contains(.setString(TestSupport.propSlotName, "Kodak Portra")))
    }

    @Test func retriesATransportFailureAndSucceeds() async throws {
        let device = FakePTPDevice(setFailuresBeforeSuccess: [film: 2])
        try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        #expect(await device.writes.count == 3)
        #expect(try await device.getInt(film) == 11)
    }

    @Test func backsOffExponentially() async throws {
        let device = FakePTPDevice(setFailuresBeforeSuccess: [film: 2])
        try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        #expect(await device.sleeps == [0.15, 0.3])
    }

    @Test func givesUpAfterConfiguredAttempts() async throws {
        let device = FakePTPDevice(setErrors: [film: CameraConnectionError("gone")])
        await #expect(throws: CameraConnectionError.self) {
            try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        }
        #expect(await device.writes.count == 3)
    }

    @Test func honoursADifferentRetryCount() async throws {
        let device = FakePTPDevice(setErrors: [film: CameraConnectionError("gone")])
        await #expect(throws: CameraConnectionError.self) {
            try await setPropWithRetry(
                device, code: film, value: .int(11), runtime: TestSupport.runtime(device, ["CAMERA_MAX_RETRIES": 5]))
        }
        #expect(await device.writes.count == 5)
    }

    @Test func doesNotRetryARejection() async throws {
        let device = FakePTPDevice(setRejectionCodes: [film: rejected])
        await #expect(throws: CameraWriteError.self) {
            try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        }
        #expect(await device.writes.count == 1)
    }

    @Test func carriesCodeValueAndRcOnARejection() async throws {
        let device = FakePTPDevice(setRejectionCodes: [film: rejected])
        do {
            try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
            Issue.record("expected CameraWriteError")
        } catch let error as CameraWriteError {
            #expect(error.code == film)
            #expect(error.value == .int(11))
            #expect(error.rc == rejected)
            #expect(error.message == "Camera rejected write of PTP property 0xD192 = 11 (rc=0x2005)")
        }
    }

    @Test func distinguishesARejectionFromAnUnreachableCamera() async throws {
        let rejecting = FakePTPDevice(setRejectionCodes: [film: rejected])
        let gone = FakePTPDevice(setErrors: [film: CameraConnectionError("gone")])
        do {
            try await setPropWithRetry(rejecting, code: film, value: .int(11), runtime: TestSupport.runtime(rejecting))
            Issue.record("expected throw")
        } catch is CameraWriteError {
        } catch { Issue.record("wrong error \(error)") }
        do {
            try await setPropWithRetry(gone, code: film, value: .int(11), runtime: TestSupport.runtime(gone))
            Issue.record("expected throw")
        } catch is CameraConnectionError {
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func unreachableMessageNamesPropertyAndValue() async throws {
        let device = FakePTPDevice(setErrors: [TestSupport.propSlotName: CameraConnectionError("gone")])
        do {
            try await setPropWithRetry(
                device, code: TestSupport.propSlotName, value: .string("Portra"), runtime: TestSupport.runtime(device))
            Issue.record("expected throw")
        } catch let error as CameraConnectionError {
            #expect(error.message == "Camera unreachable after 3 attempts writing 0xD18D = 'Portra'")
        }
    }
}

@Suite("setCursorWithRetry")
struct SetCursorWithRetryTests {
    @Test func sendsAUint16() async throws {
        let device = FakePTPDevice()
        try await setCursorWithRetry(device, slotIndex: 3, runtime: TestSupport.runtime(device))
        #expect(await device.events == [.setUInt16(TestSupport.propSlotCursor, 3)])
    }

    @Test func doesNotRetryARefusal() async throws {
        let device = FakePTPDevice(setRejectionCodes: [TestSupport.propSlotCursor: rejected])
        await #expect(throws: CameraWriteError.self) {
            try await setCursorWithRetry(device, slotIndex: 3, runtime: TestSupport.runtime(device))
        }
        #expect(await device.writes.count == 1)
    }

    @Test func retriesTransportFailures() async throws {
        let device = FakePTPDevice(setFailuresBeforeSuccess: [TestSupport.propSlotCursor: 2])
        try await setCursorWithRetry(device, slotIndex: 3, runtime: TestSupport.runtime(device))
        #expect(await device.sleeps == [0.15, 0.3])
    }
}

@Suite("verifyWrittenProperties")
struct VerifyWrittenPropertiesTests {
    let film = TestSupport.code("FilmSimulation")
    let other: UInt16 = 0xd195

    @Test func reportsNothingWhenEveryValueStuck() async throws {
        let device = FakePTPDevice()
        try await setPropWithRetry(device, code: film, value: .int(11), runtime: TestSupport.runtime(device))
        let mismatched = try await verifyWrittenProperties(
            device, written: [(film, .int(11))], runtime: TestSupport.runtime(device))
        #expect(mismatched.isEmpty)
    }

    @Test func reportsAPropertyTheCameraChangedUnderneath() async throws {
        let device = FakePTPDevice(intReadOverrides: [film: 6])
        let mismatched = try await verifyWrittenProperties(
            device, written: [(film, .int(11))], runtime: TestSupport.runtime(device))
        #expect(mismatched == [film])
    }

    @Test func comparesNegativesAsSixteenBits() async throws {
        let device = FakePTPDevice(intReadOverrides: [film: 0xffd8])
        let mismatched = try await verifyWrittenProperties(
            device, written: [(film, .int(-40))], runtime: TestSupport.runtime(device))
        #expect(mismatched.isEmpty)
    }

    @Test func comparesStringsExactly() async throws {
        let device = FakePTPDevice(strReadOverrides: [TestSupport.propSlotName: "Kodak Port"])
        let mismatched = try await verifyWrittenProperties(
            device, written: [(TestSupport.propSlotName, .string("Kodak Portra"))], runtime: TestSupport.runtime(device))
        #expect(mismatched == [TestSupport.propSlotName])
    }

    @Test func treatsAFailedReadAsAMismatchRatherThanThrowing() async throws {
        let device = FakePTPDevice(defaultIntGetError: CameraConnectionError("gone"))
        let mismatched = try await verifyWrittenProperties(
            device, written: [(film, .int(11)), (other, .int(2))], runtime: TestSupport.runtime(device))
        #expect(mismatched == [film, other])
    }

    @Test func pausesBeforeEachRead() async throws {
        let device = FakePTPDevice()
        let runtime = try TestSupport.runtime(device, ["CAMERA_PRE_WRITE_DELAY_S": 0.05])
        _ = try await verifyWrittenProperties(device, written: [(film, .int(0)), (other, .int(0))], runtime: runtime)
        #expect(await device.events == [.sleep(0.05), .getInt(film), .sleep(0.05), .getInt(other)])
    }

    @Test func checksEveryPropertyRatherThanStoppingAtTheFirstMismatch() async throws {
        let device = FakePTPDevice(intReadOverrides: [film: 6, other: 9])
        let mismatched = try await verifyWrittenProperties(
            device, written: [(film, .int(11)), (other, .int(2))], runtime: TestSupport.runtime(device))
        #expect(mismatched == [film, other])
    }
}

@Suite("getStrategy")
struct GetStrategyTests {
    @Test("resolves known and unknown models to the per-property strategy", arguments: ["X-S10", "NOT-A-CAMERA", ""])
    func resolves(_ name: String) {
        let strategy: any CameraStrategy = getStrategy(cameraName: name)
        #expect(strategy is PerPropertyStrategy)
    }
}

@Suite("error formatting")
struct ErrorFormattingTests {
    @Test func recipeWriteErrorReadsLikeThePythonMessage() {
        let error = RecipeWriteError(failedProperties: ["SlotName", "FilmSimulation"])
        #expect(error.message == "Recipe write incomplete: 2 property/properties failed (['SlotName', 'FilmSimulation'])")
    }

    @Test func formatsCodesAndResponseCodes() {
        #expect(formatCode(0xd18c) == "0xD18C")
        #expect(formatCode(0x1) == "0x0001")
        #expect(formatRc(0x2005) == "0x2005")
    }
}
