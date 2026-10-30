// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation
import Observation

/// MODEL GAP (see open_questions): FilmcaseKit has no model for the backups list on the Camera
/// tab. This thin app-side model wraps the store and workflow so the view stays declarative;
/// it should move into FilmcaseKit (with tests) and replace this.
@MainActor
@Observable
final class CameraBackupsModel {
    private(set) var backups: [SlotBackup] = []
    private(set) var message: String?
    private(set) var isRestoring = false
    private(set) var successCount = 0

    @ObservationIgnored private let store: any BackupStore
    @ObservationIgnored private let workflow: SlotBackupWorkflow

    init(store: any BackupStore, workflow: SlotBackupWorkflow) {
        self.store = store
        self.workflow = workflow
    }

    /// The store returns newest first; keep the first seen per camera and slot.
    func load() async {
        do {
            var seen = Set<String>()
            backups = try await store.all().filter {
                seen.insert("\($0.cameraName)#\($0.slotIndex)").inserted
            }
        } catch {
            message = UserMessages.text(for: error)
        }
    }

    func restore(_ backup: SlotBackup) async {
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            switch try await workflow.restore(backup) {
            case .verified:
                successCount += 1
                message = "C\(backup.slotIndex) restored."
            case .partiallyFailed(let names):
                message = "C\(backup.slotIndex): the camera did not take \(names.joined(separator: ", "))."
            case .connectionLost:
                message = "The camera connection was lost."
            }
        } catch {
            message = UserMessages.text(for: error)
        }
    }
}
