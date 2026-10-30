// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation
import SwiftData

/// The stored form of a `SlotBackup`. Never leaves `SwiftDataBackupStore`: callers only see
/// the `SlotBackup` value type.
// API: @Model (SwiftData, iOS 17+) makes this class a persisted entity and synthesizes
// PersistentModel + Observable. Not Sendable by design; it stays inside the model actor.
@Model
final class BackupRecord {
    // API: #Unique (SwiftData, iOS 18+) makes `id` a unique key; inserting a second record
    // with the same id upserts instead of duplicating.
    #Unique<BackupRecord>([\.id])

    // API: #Index (SwiftData, iOS 18+) adds indexes for the `latest(slot:camera:)` lookup and
    // for the arrival-order sort.
    #Index<BackupRecord>([\.cameraName, \.slotIndex, \.capturedAt], [\.sequence])

    var id: UUID
    var cameraName: String
    var slotIndex: Int
    var capturedAt: Date
    var slotName: String
    /// JSON of `[BackupProperty]` (Codable in FilmcaseKit), in the server's write order.
    var propertiesJSON: Data
    /// Insertion order. `InMemoryBackupStore` orders by arrival, not by `capturedAt`, so ties
    /// and out-of-order timestamps must resolve the same way here.
    var sequence: Int

    init(
        id: UUID, cameraName: String, slotIndex: Int, capturedAt: Date, slotName: String,
        propertiesJSON: Data, sequence: Int
    ) {
        self.id = id
        self.cameraName = cameraName
        self.slotIndex = slotIndex
        self.capturedAt = capturedAt
        self.slotName = slotName
        self.propertiesJSON = propertiesJSON
        self.sequence = sequence
    }

    convenience init(_ backup: SlotBackup, sequence: Int) throws {
        self.init(
            id: backup.id, cameraName: backup.cameraName, slotIndex: backup.slotIndex,
            capturedAt: backup.capturedAt, slotName: backup.slotName,
            propertiesJSON: try JSONEncoder().encode(backup.properties), sequence: sequence)
    }

    /// The value type handed across the actor boundary.
    func snapshot() throws -> SlotBackup {
        SlotBackup(
            id: id, cameraName: cameraName, slotIndex: slotIndex, capturedAt: capturedAt,
            slotName: slotName,
            properties: try JSONDecoder().decode([BackupProperty].self, from: propertiesJSON))
    }
}
