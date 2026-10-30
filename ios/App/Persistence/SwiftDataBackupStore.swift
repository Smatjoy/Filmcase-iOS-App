// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation
import SwiftData

/// `BackupStore` on SwiftData. Same semantics as `InMemoryBackupStore`: `all()` is newest
/// first by arrival, `latest` is the last arrival for the slot and camera, `delete` is a
/// no-op for an unknown id. Records are mapped to `SlotBackup` values inside the actor;
/// no `@Model` crosses its boundary.
// API: @ModelActor (SwiftData, iOS 17+) synthesizes `modelContainer`, `modelExecutor`,
// `modelContext` and `init(modelContainer:)`, and runs the actor on the context's executor.
@ModelActor
actor SwiftDataBackupStore: BackupStore {
    /// One schema for the app and the tests.
    static let schema = Schema([BackupRecord.self])

    /// The on-disk container for the live app: Application Support, no CloudKit.
    // API: ModelConfiguration(_:schema:url:allowsSave:cloudKitDatabase:) (iOS 17+); `.none` opts out of sync.
    static func makeLiveContainer() throws -> ModelContainer {
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            "Backups", schema: schema, url: directory.appending(path: "Backups.store"),
            cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// In memory, for tests and previews.
    // API: ModelConfiguration(isStoredInMemoryOnly:) (iOS 17+).
    static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    func save(_ backup: SlotBackup) throws {
        // `#Unique` upserts on a repeated id; keep that explicit and keep arrival order fresh.
        // API: ModelContext.delete(model:where:) (iOS 17+).
        let id = backup.id
        try modelContext.delete(model: BackupRecord.self, where: #Predicate { $0.id == id })
        // API: FetchDescriptor(sortBy:) + fetchLimit (iOS 17+).
        var newest = FetchDescriptor<BackupRecord>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        newest.fetchLimit = 1
        let next = (try modelContext.fetch(newest).first?.sequence ?? 0) + 1
        // API: ModelContext.insert(_:) / save() (iOS 17+). Always save explicitly in a ModelActor.
        modelContext.insert(try BackupRecord(backup, sequence: next))
        try modelContext.save()
    }

    func latest(slot: Int, camera: String) throws -> SlotBackup? {
        // API: #Predicate (Foundation, iOS 17+).
        var descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.slotIndex == slot && $0.cameraName == camera },
            sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.snapshot()
    }

    func all() throws -> [SlotBackup] {
        let descriptor = FetchDescriptor<BackupRecord>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        return try modelContext.fetch(descriptor).map { try $0.snapshot() }
    }

    func delete(id: SlotBackup.ID) throws {
        try modelContext.delete(model: BackupRecord.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }
}
