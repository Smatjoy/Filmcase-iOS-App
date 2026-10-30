import FilmcaseKit
import Foundation
import SwiftData
import Testing

@testable import Filmcase

@Suite struct SwiftDataBackupStoreTests {
    private func makeStore() throws -> SwiftDataBackupStore {
        SwiftDataBackupStore(modelContainer: try SwiftDataBackupStore.makeInMemoryContainer())
    }

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func backup(
        _ n: Int, camera: String = "X-T50", slot: Int = 1, at offset: TimeInterval = 0,
        name: String = "Slot"
    ) -> SlotBackup {
        SlotBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            cameraName: camera, slotIndex: slot, capturedAt: Self.t0.addingTimeInterval(offset),
            slotName: name,
            properties: [
                BackupProperty(name: "FilmSimulation", code: 0xD192, value: 7),
                BackupProperty(name: "HighLightTone", code: 0xD19F, value: -20),
                BackupProperty(name: "GrainEffect", code: 0xD195, value: 65535),
            ])
    }

    @Test func emptyStoreHasNothing() async throws {
        let store = try makeStore()
        #expect(try await store.all().isEmpty)
        #expect(try await store.latest(slot: 1, camera: "X-T50") == nil)
    }

    @Test func saveThenLatestAndAllOrdering() async throws {
        let store = try makeStore()
        let first = backup(1, slot: 1, at: 0)
        let second = backup(2, slot: 2, at: 10)
        let third = backup(3, slot: 1, at: 20)
        for b in [first, second, third] { try await store.save(b) }

        #expect(try await store.latest(slot: 1, camera: "X-T50") == third)
        #expect(try await store.latest(slot: 2, camera: "X-T50") == second)
        #expect(try await store.latest(slot: 1, camera: "X-S20") == nil)
        #expect(try await store.all() == [third, second, first])
    }

    @Test func arrivalOrderWinsOverCapturedAt() async throws {
        let store = try makeStore()
        let later = backup(1, at: 100)
        let earlier = backup(2, at: 0)
        try await store.save(later)
        try await store.save(earlier)
        #expect(try await store.latest(slot: 1, camera: "X-T50") == earlier)
        #expect(try await store.all() == [earlier, later])
    }

    @Test func deleteRemovesOnlyThatBackup() async throws {
        let store = try makeStore()
        let first = backup(1)
        let second = backup(2)
        try await store.save(first)
        try await store.save(second)

        try await store.delete(id: second.id)
        #expect(try await store.all() == [first])
        #expect(try await store.latest(slot: 1, camera: "X-T50") == first)

        try await store.delete(id: UUID())  // unknown id is a no-op
        #expect(try await store.all() == [first])
    }

    @Test func roundTripsEveryField() async throws {
        let store = try makeStore()
        let original = backup(9, camera: "X-T50", slot: 5, at: 3.25, name: "Kodak Portra 400")
        try await store.save(original)

        let loaded = try #require(try await store.latest(slot: 5, camera: "X-T50"))
        #expect(loaded.id == original.id)
        #expect(loaded.cameraName == original.cameraName)
        #expect(loaded.slotIndex == original.slotIndex)
        #expect(loaded.slotName == original.slotName)
        #expect(loaded.capturedAt == original.capturedAt)
        #expect(loaded.properties == original.properties)  // name, code, value, and order
        #expect(loaded.filmSimPtp == 7)
    }

    /// The same operations against both stores must give the same answers.
    @Test func matchesInMemoryStore() async throws {
        let memory = InMemoryBackupStore()
        let persisted = try makeStore()
        let stores: [any BackupStore] = [memory, persisted]

        let ops = [
            backup(1, slot: 1, at: 50), backup(2, slot: 2, at: 40), backup(3, slot: 1, at: 50),
            backup(4, camera: "X-S20", slot: 1, at: 60), backup(5, slot: 1, at: 10),
        ]
        var results: [[String]] = [[], []]

        func snapshot(_ store: any BackupStore) async throws -> String {
            let all = try await store.all()
            let a = try await store.latest(slot: 1, camera: "X-T50")
            let b = try await store.latest(slot: 2, camera: "X-T50")
            let c = try await store.latest(slot: 1, camera: "X-S20")
            let d = try await store.latest(slot: 3, camera: "X-T50")
            return "\(all)|\(String(describing: a))|\(String(describing: b))|\(String(describing: c))|\(String(describing: d))"
        }

        for (i, store) in stores.enumerated() {
            for op in ops {
                try await store.save(op)
                results[i].append(try await snapshot(store))
            }
            try await store.delete(id: ops[4].id)
            results[i].append(try await snapshot(store))
            try await store.delete(id: ops[0].id)
            results[i].append(try await snapshot(store))
            try await store.delete(id: UUID())
            results[i].append(try await snapshot(store))
        }

        #expect(results[0] == results[1])
        #expect(try await memory.all() == persisted.all())
    }
}
