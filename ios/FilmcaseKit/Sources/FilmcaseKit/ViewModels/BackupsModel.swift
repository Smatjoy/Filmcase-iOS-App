// The Camera tab's list of slot backups: the latest backup of each slot on each camera, and a
// restore that reports in words. Replaces the app-side CameraBackupsModel.

import Foundation
import Observation

@MainActor
@Observable
public final class BackupsModel {
    /// The latest backup per camera and slot, newest first.
    public private(set) var backups: [SlotBackup] = []
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

    /// The store returns newest first; keep the first seen per camera and slot.
    public func load() async {
        do {
            var seen = Set<String>()
            backups = try await store.all().filter {
                seen.insert("\($0.cameraName)#\($0.slotIndex)").inserted
            }
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
    }
}
