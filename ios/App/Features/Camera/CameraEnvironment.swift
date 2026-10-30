// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// What the camera feature needs from the app. AppEnvironment conforms (P6b/lead wire it).
@MainActor protocol CameraFeatureEnvironment: AnyObject {
    var cameraConnection: CameraConnection { get }
    var client: FilmcaseClient { get }
    func backupStore() -> any BackupStore
    func cameraRuntime() async throws -> CameraRuntime   // built from served client config
    var clock: any FilmcaseClock { get }
}

extension CameraFeatureEnvironment {
    /// Composition only: the models' initializers take these pieces.
    func makeCameraModel() async throws -> CameraModel {
        CameraModel(connection: cameraConnection, runtime: try await cameraRuntime())
    }

    func makeSlotWorkflow() async throws -> SlotBackupWorkflow {
        SlotBackupWorkflow(
            runner: cameraConnection, store: backupStore(),
            runtime: try await cameraRuntime(), clock: clock)
    }
}
