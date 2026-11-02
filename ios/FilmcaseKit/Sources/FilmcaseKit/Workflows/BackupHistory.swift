// Every backup of a slot, newest first, and the one that matters most: the oldest. Filmcase
// always backs a slot up before its first write, so the oldest backup per camera and slot is
// what the slot held before Filmcase touched it ("Before Filmcase"). That needs no stored
// flag, so it works for stores written before this existed.

import Foundation

/// One backup in a slot's history.
public struct BackupHistoryEntry: Equatable, Identifiable, Sendable {
    public let backup: SlotBackup
    /// True for the oldest backup of the slot on that camera model.
    public let isBeforeFilmcase: Bool

    public var id: SlotBackup.ID { backup.id }
    public var capturedAt: Date { backup.capturedAt }
}

/// All the backups of one slot on one camera model, newest first.
public struct SlotBackupHistory: Equatable, Identifiable, Sendable {
    public let cameraName: String
    public let slotIndex: Int
    public let entries: [BackupHistoryEntry]

    public var id: String { "\(cameraName)#\(slotIndex)" }
    /// The newest backup; histories are never empty.
    public var latest: BackupHistoryEntry { entries[0] }
    /// The oldest backup: what the slot held before Filmcase.
    public var original: BackupHistoryEntry { entries[entries.count - 1] }
    /// Everything but the newest, shown when the slot is expanded.
    public var earlier: [BackupHistoryEntry] { Array(entries.dropFirst()) }

    /// Group *newestFirst* (the order `BackupStore.all()` returns) per camera and slot.
    /// Cameras keep the order of their newest backup; slots run C1 upwards.
    public static func group(_ newestFirst: [SlotBackup]) -> [SlotBackupHistory] {
        var keys: [String] = []
        var byKey: [String: [SlotBackup]] = [:]
        var cameras: [String] = []
        for backup in newestFirst {
            let key = "\(backup.cameraName)#\(backup.slotIndex)"
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(backup)
            if !cameras.contains(backup.cameraName) { cameras.append(backup.cameraName) }
        }
        let histories = keys.compactMap { key -> SlotBackupHistory? in
            guard let backups = byKey[key], let first = backups.first else { return nil }
            let entries = backups.enumerated().map { offset, backup in
                BackupHistoryEntry(backup: backup, isBeforeFilmcase: offset == backups.count - 1)
            }
            return SlotBackupHistory(cameraName: first.cameraName, slotIndex: first.slotIndex, entries: entries)
        }
        return histories.sorted {
            if $0.cameraName != $1.cameraName {
                return (cameras.firstIndex(of: $0.cameraName) ?? 0) < (cameras.firstIndex(of: $1.cameraName) ?? 0)
            }
            return $0.slotIndex < $1.slotIndex
        }
    }

    /// The original of every slot of *camera*, in slot order.
    public static func originals(in newestFirst: [SlotBackup], camera: String) -> [SlotBackup] {
        group(newestFirst).filter { $0.cameraName == camera }.map(\.original.backup)
    }
}

extension SlotBackupWorkflow {
    /// The camera model that is connected, if any.
    var connectedCameraName: String? {
        get async { await runner.cameraName }
    }

    /// Restore each of *originals* in the order given, stopping when the connection is lost.
    /// Each restore backs its slot up first. Results are kept in *results* as they come, so a
    /// thrown error still leaves the slots already done reported.
    func restoreOriginals(
        _ originals: [SlotBackup], results: inout [Int: SlotPushResult]
    ) async throws {
        for backup in originals {
            let result = try await restore(backup)
            results[backup.slotIndex] = result
            if result == .connectionLost { break }
        }
    }
}
