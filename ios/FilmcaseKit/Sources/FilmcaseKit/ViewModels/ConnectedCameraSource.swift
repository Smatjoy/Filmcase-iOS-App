import Foundation

/// A camera that is connected right now, with what is needed to judge a recipe against it.
public struct ConnectedCamera: Equatable, Sendable {
    public let name: String
    public let encodings: ClientEncodings

    public init(name: String, encodings: ClientEncodings) {
        self.name = name
        self.encodings = encodings
    }
}

/// Answers "which camera is connected?" for models that only need to know that.
public protocol ConnectedCameraSource: Sendable {
    func connectedCamera() async -> ConnectedCamera?
}

/// The production source: the connection's current model plus the served encodings.
public struct RunnerCameraSource: ConnectedCameraSource {
    let runner: any CameraOperationRunner
    let encodings: ClientEncodings

    public init(runner: any CameraOperationRunner, encodings: ClientEncodings) {
        self.runner = runner
        self.encodings = encodings
    }

    public func connectedCamera() async -> ConnectedCamera? {
        guard let name = await runner.cameraName else { return nil }
        return ConnectedCamera(name: name, encodings: encodings)
    }
}
