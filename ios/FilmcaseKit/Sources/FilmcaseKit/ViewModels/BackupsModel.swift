// The Camera tab's backups: the latest backup of each slot, the full history behind it, a
// restore that reports in words, and "restore originals" (the oldest backup of every slot,
// which is what the slot held before Filmcase). Replaces the app-side CameraBackupsModel.

import Foundation
import Observation

@MainActor
@Observable
public final class BackupsModel {
    /// The latest backup per camera and slot, newest first.
    public private(set) var backups: [SlotBackup] = []
    /// Every backup grouped per camera and slot (C1 upwards), each group newest first, the
    /// oldest entry flagged `isBeforeFilmcase`.
    public private(set) var histories: [SlotBackupHistory] = []
    /// The confirmation to show before `restoreOriginals()`; nil when none is pending.
    public private(set) var restoreOriginalsPrompt: String?
    /// The result of the last load or restore, as a sentence; nil when there is nothing to say.
    public private(set) var message: String?
    public private(set) var isRestoring = false
    /// Count of verified restores, for `.sensoryFeedback(.success, trigger:)`.
    public private(set) var successCount = 0

    @ObservationIgnored private let store: any BackupStore
    @ObservationIgnored private let workflow: SlotBackupWorkflow

    public init(store: any BackupStore, workflow: SlotBackupWorkflow) {
        self.store = store
        self.workflow = workflow
    }

    /// The badge text for an entry that is `isBeforeFilmcase`.
    public var beforeFilmcaseBadge: String { UserMessages.beforeFilmcaseBadge }
    public var restoreOriginalsLabel: String { UserMessages.restoreOriginalsLabel }

    /// True when there is a backup to put back.
    public var canRestoreOriginals: Bool { !histories.isEmpty && !isRestoring }

    /// The store returns newest first; keep the first seen per camera and slot.
    public func load() async {
        do {
            let all = try await store.all()
            var seen = Set<String>()
            backups = all.filter { seen.insert("\($0.cameraName)#\($0.slotIndex)").inserted }
            histories = SlotBackupHistory.group(all)
        } catch {
            message = UserMessages.text(for: error)
        }
    }

    public func restore(_ backup: SlotBackup) async {
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            let result = try await workflow.restore(backup)
            if result == .verified { successCount += 1 }
            message = UserMessages.restoreText(slot: backup.slotIndex, result: result)
        } catch is CancellationError {
            return
        } catch {
            message = UserMessages.text(for: error)
        }
        await reloadKeepingMessage()
    }

    /// Work out what restoring the originals would bring back and set
    /// `restoreOriginalsPrompt` for the view to confirm. With no camera connected, or nothing
    /// to restore, `message` says so instead.
    public func requestRestoreOriginals() async {
        message = nil
        restoreOriginalsPrompt = nil
        do {
            guard let originals = try await connectedOriginals() else {
                message = UserMessages.text(for: CollectionPushError.notConnected)
                return
            }
            if originals.isEmpty {
                message = UserMessages.noOriginalsText
            } else {
                restoreOriginalsPrompt = UserMessages.restoreOriginalsPrompt(originals: originals)
            }
        } catch {
            message = UserMessages.text(for: error)
        }
    }

    public func cancelRestoreOriginals() { restoreOriginalsPrompt = nil }

    /// Put the oldest backup of every slot of the connected camera model back, in slot order.
    /// Each slot is backed up first, so this too can be undone from the history.
    public func restoreOriginals() async {
        restoreOriginalsPrompt = nil
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        var results: [Int: SlotPushResult] = [:]
        do {
            guard let originals = try await connectedOriginals() else {
                message = UserMessages.text(for: CollectionPushError.notConnected)
                return
            }
            try await workflow.restoreOriginals(originals, results: &results)
            if !results.isEmpty, results.values.allSatisfy({ $0 == .verified }) { successCount += 1 }
            message = UserMessages.restoreOriginalsText(results: results)
        } catch is CancellationError {
            return
        } catch {
            let done = results.isEmpty ? "" : UserMessages.restoreOriginalsText(results: results) + " "
            message = done + UserMessages.text(for: error)
        }
        await reloadKeepingMessage()
    }

    /// nil when no camera is connected.
    private func connectedOriginals() async throws -> [SlotBackup]? {
        guard let camera = await workflow.connectedCameraName else { return nil }
        return SlotBackupHistory.originals(in: try await store.all(), camera: camera)
    }

    /// A restore stores a backup of its own, so the lists change. `load` leaves `message`
    /// alone unless the store cannot be read.
    private func reloadKeepingMessage() async {
        await load()
    }
}
