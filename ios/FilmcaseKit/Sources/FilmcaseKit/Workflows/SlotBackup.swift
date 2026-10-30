// What "back up before overwriting" stores, and where. The SwiftData adapter implements
// BackupStore in the app; InMemoryBackupStore serves tests and the demo flavor.

import Foundation

/// One property of a slot as the camera reported it, raw: the PTP value, not a recipe field.
/// Restoring writes these values back as they are, so nothing is lost converting to a Recipe.
public struct BackupProperty: Equatable, Codable, Sendable {
    /// The served property name (`FilmSimulation`, `HighLightTone`, ...).
    public let name: String
    public let code: UInt16
    public let value: Int

    public init(name: String, code: UInt16, value: Int) {
        self.name = name
        self.code = code
        self.value = value
    }
}

/// A slot's contents as they were before a push.
public struct SlotBackup: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let cameraName: String
    /// 1-based custom slot (C1 = 1).
    public let slotIndex: Int
    public let capturedAt: Date
    public let slotName: String
    /// In the server's write order, so a restore writes in the order a push would.
    public let properties: [BackupProperty]

    public init(
        id: UUID = UUID(), cameraName: String, slotIndex: Int, capturedAt: Date,
        slotName: String, properties: [BackupProperty]
    ) {
        self.id = id
        self.cameraName = cameraName
        self.slotIndex = slotIndex
        self.capturedAt = capturedAt
        self.slotName = slotName
        self.properties = properties
    }

    /// The raw film simulation value, for showing what the slot held.
    public var filmSimPtp: Int? {
        properties.first { $0.name == "FilmSimulation" }?.value
    }
}

public protocol BackupStore: Sendable {
    func save(_ backup: SlotBackup) async throws
    /// The most recent backup of a slot on a camera model, if any.
    func latest(slot: Int, camera: String) async throws -> SlotBackup?
    /// Every backup, newest first.
    func all() async throws -> [SlotBackup]
    func delete(id: SlotBackup.ID) async throws
}

public actor InMemoryBackupStore: BackupStore {
    private var backups: [SlotBackup] = []

    public init() {}

    public func save(_ backup: SlotBackup) {
        backups.append(backup)
    }

    public func latest(slot: Int, camera: String) -> SlotBackup? {
        backups.last { $0.slotIndex == slot && $0.cameraName == camera }
    }

    public func all() -> [SlotBackup] {
        backups.reversed()
    }

    public func delete(id: SlotBackup.ID) {
        backups.removeAll { $0.id == id }
    }
}
