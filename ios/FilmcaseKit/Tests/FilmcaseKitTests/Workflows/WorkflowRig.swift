// A connected X-T50 (7 custom slots) whose slot holds known "original" values, wired to the
// backup workflow with the delays served in push_vectors.json (recorded on the device's
// timeline, so a test can assert the order of reads, writes and sleeps).

import Foundation
import Testing
@testable import FilmcaseKit

struct WorkflowRig {
    let rig: ConnectionRig
    let store: any BackupStore
    let workflow: SlotBackupWorkflow
    /// Drives the collection push's inter-slot waits; separate from the connection's timeout clock.
    let collectionClock = TestClock()

    var device: FakePTPDevice { rig.device }
    var transport: FakeCameraTransport { rig.transport }

    static let originalName = "ORIGINAL"

    /// Distinct raw value per property, none of which a recipe conversion produces by accident.
    static var originalValues: [UInt16: Int] {
        var values: [UInt16: Int] = [:]
        for (index, name) in TestSupport.encodings.writeOrder.enumerated() {
            values[TestSupport.code(name)] = 900 + index
        }
        return values
    }

    /// - Parameter verify: `CAMERA_VERIFY_WRITES` for pushes.
    init(
        store: any BackupStore = InMemoryBackupStore(), verify: Bool = true,
        interSlotDelay: Double? = nil,
        stallOnCalls: Set<Int> = [], unplugOnCall: Int? = nil,
        setRejectionCodes: [UInt16: Int] = [:]
    ) async throws {
        var strings: [UInt16: String] = [:]
        strings[TestSupport.propSlotName] = Self.originalName
        rig = try ConnectionRig(
            intValues: Self.originalValues, stringValues: strings,
            stallOnCalls: stallOnCalls, unplugOnCall: unplugOnCall, setRejectionCodes: setRejectionCodes)
        self.store = store

        let vectors = try #require(PushVectors.shared)
        var settings: [String: Any] = vectors.settings.mapValues(\.foundation)
        settings["CAMERA_VERIFY_WRITES"] = verify
        if let interSlotDelay { settings["CAMERA_INTER_SLOT_DELAY_S"] = interSlotDelay }
        let runtime = try TestSupport.runtime(rig.device, settings)
        workflow = SlotBackupWorkflow(
            runner: rig.connection, store: store, runtime: runtime, clock: collectionClock)
        await rig.connectAndWaitUntilReady()
    }

    /// Recipes named R1...Rn, all the same valid configuration.
    static func recipes(_ count: Int) throws -> [RecipeID: Recipe] {
        var recipes: [RecipeID: Recipe] = [:]
        for id in 1...count {
            var recipe = try TestSupport.makeRecipe()
            recipe.name = "R\(id)"
            recipes[id] = recipe
        }
        return recipes
    }

    /// Writes that are not slot-cursor moves, in order.
    var propertyWrites: [(code: UInt16, value: PTPPropertyValue)] {
        get async { await device.writes.filter { $0.code != TestSupport.propSlotCursor } }
    }

    /// The slot-name values written, in order.
    var nameWrites: [String] {
        get async {
            await device.writes.compactMap { write in
                if write.code == TestSupport.propSlotName, case .string(let name) = write.value { return name }
                return nil
            }
        }
    }
}

/// A store whose saves always fail.
struct FailingBackupStore: BackupStore {
    struct Failure: Error {}
    func save(_ backup: SlotBackup) async throws { throw Failure() }
    func latest(slot: Int, camera: String) async throws -> SlotBackup? { nil }
    func all() async throws -> [SlotBackup] { [] }
    func delete(id: SlotBackup.ID) async throws {}
}
