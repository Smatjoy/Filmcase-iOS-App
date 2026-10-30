// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// What the camera feature needs from the app. `AppEnvironment` conforms.
@MainActor protocol CameraFeatureEnvironment: AnyObject {
    var connection: CameraConnection { get }
    var client: FilmcaseClient { get }
    var backupStore: any BackupStore { get }
    var cameraRuntime: CameraRuntime { get }
    /// The one CameraModel the app shares (tab-bar pill, Camera tab, Send sheet), so
    /// only one model observes the connection.
    var cameraModel: CameraModel { get }
    var clock: any FilmcaseClock { get }
}

extension CameraFeatureEnvironment {
    /// Composition only: the models' initializers take these pieces.
    func makeCameraModel() async throws -> CameraModel {
        cameraModel
    }

    func makeSlotWorkflow() async throws -> SlotBackupWorkflow {
        SlotBackupWorkflow(runner: connection, store: backupStore, runtime: cameraRuntime, clock: clock)
    }
}
