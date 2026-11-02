// "What is on my camera?" for Siri and Shortcuts: the custom slots, and a sentence to speak.

import Foundation

public struct SlotSummary: Equatable, Hashable, Codable, Sendable, Identifiable {
    public let index: Int
    /// The slot's name, empty for an empty slot.
    public let name: String
    public let filmSimulation: String

    public var id: Int { index }
    public var title: String { "C\(index)" }
    public var isEmpty: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// "C1 Kodak Portra 400" or "C2 empty".
    public var spoken: String { "\(title) \(isEmpty ? "empty" : name)" }

    public init(index: Int, name: String, filmSimulation: String) {
        self.index = index
        self.name = name
        self.filmSimulation = filmSimulation
    }
}

public struct ReadSlotsOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case slots
        case noCamera
        /// The connected model has no custom slots.
        case noCustomSlots(cameraName: String)
        case connectionLost
        case failed(String)
        case cancelled
    }

    public let result: Result
    /// Empty unless `result == .slots`.
    public let slots: [SlotSummary]
    /// The sentence for Siri or the Shortcuts result.
    public let dialog: String
}

public struct ReadSlotsAction: Sendable {
    private let runner: any CameraOperationRunner
    private let runtimeSource: any CameraRuntimeSource

    public init(runner: any CameraOperationRunner, runtimeSource: any CameraRuntimeSource) {
        self.runner = runner
        self.runtimeSource = runtimeSource
    }

    /// Read every custom slot. Never throws: every failure is an outcome with its own dialog.
    public func perform() async -> ReadSlotsOutcome {
        func outcome(_ result: ReadSlotsOutcome.Result, _ dialog: String, slots: [SlotSummary] = []) -> ReadSlotsOutcome {
            ReadSlotsOutcome(result: result, slots: slots, dialog: dialog)
        }
        guard let cameraName = await runner.cameraName else {
            return outcome(.noCamera, SendRecipeToSlotAction.noCameraDialog)
        }
        let runtime = await runtimeSource.currentRuntime()
        do {
            let states = try await runner.run("Read slots") { device in
                try await getCameraSlots(device, runtime: runtime)
            }
            guard !states.isEmpty else {
                return outcome(.noCustomSlots(cameraName: cameraName), "\(cameraName) has no custom slots.")
            }
            let slots = states.map { SlotSummary(index: $0.index, name: $0.name, filmSimulation: $0.filmSimName) }
            return outcome(.slots, slots.map(\.spoken).joined(separator: ", ") + ".", slots: slots)
        } catch is CancellationError {
            return outcome(.cancelled, "Cancelled.")
        } catch {
            if isConnectionFailure(error) {
                return outcome(.connectionLost, "The camera connection was lost. Check the cable and try again.")
            }
            return outcome(.failed(UserMessages.text(for: error)), UserMessages.text(for: error))
        }
    }
}
