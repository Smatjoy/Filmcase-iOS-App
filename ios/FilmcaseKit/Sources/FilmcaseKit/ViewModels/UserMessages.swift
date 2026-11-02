// Every user-facing error string lives here, so wording is decided (and tested) in one
// place and views never format an error themselves.

import Foundation

public enum UserMessages {
    /// The sentence to show for *error*.
    public static func text(for error: any Error) -> String {
        switch error {
        case let error as FilmcaseClientError: return text(for: error)
        case let error as SlotBackupError: return text(for: error)
        case let error as CollectionPushError: return text(for: error)
        case let error as ConnectionError: return text(for: error)
        case let error as RecipeValidationError:
            return "The camera cannot take this recipe: \(error.description)"
        case let error as RecipeConversionError:
            return "This recipe cannot be converted for the camera: \(String(describing: error))"
        case let error as CameraConnectionError:
            return "The camera stopped answering. \(error.message)"
        case let error as RecipeWriteError:
            return "The camera refused: \(error.failedProperties.joined(separator: ", "))."
        default:
            return "Something went wrong."
        }
    }

    public static func text(for error: FilmcaseClientError) -> String {
        switch error {
        case .unauthorized:
            "The server rejected the token."
        case .serverNotConfigured:
            "The server has no API token configured."
        case .notFound:
            "The server could not find that."
        case .badRequest(let message):
            "The server refused the request: \(message)"
        case .unexpectedStatus(let status):
            "The server answered with an unexpected status (\(status))."
        case .transport:
            "The connection to the server failed."
        case .decoding:
            "The server sent a response the app could not read."
        case .pinMismatch(let host):
            "The certificate for \(host) changed since you trusted it."
        case .unpinnedHost(let host, _):
            "\(host) has not been trusted yet."
        case .noReachableServer:
            "No server answered. Check the URLs and that you are on the right network."
        }
    }

    public static func text(for error: SlotBackupError) -> String {
        switch error {
        case .slotOutOfRange(let slot, let slotCount):
            slotCount == 0
                ? "This camera has no custom slots."
                : "C\(slot) does not exist on this camera (C1 to C\(slotCount))."
        case .backupNotSaved:
            "The slot could not be backed up, so nothing was changed."
        case .wrongCamera(let backup, let connected):
            "That backup is from a \(backup), but a \(connected) is connected."
        }
    }

    public static func text(for error: CollectionPushError) -> String {
        switch error {
        case .emptyAssignment:
            "Assign at least one recipe to a slot."
        case .slotOutOfRange(let slot, let slotCount):
            "C\(slot) does not exist on this camera (C1 to C\(slotCount))."
        case .duplicateSlot(let slot):
            "C\(slot) is assigned twice."
        case .unknownRecipe:
            "A recipe in this collection could not be loaded."
        case .invalidRecipe(let slot, let message):
            "C\(slot): \(message)"
        case .notConnected:
            "No camera is connected."
        case .stopped(_, let message):
            "The push stopped: \(message)"
        }
    }

    public static func text(for error: ConnectionError) -> String {
        switch error {
        case .busy:
            "The camera is busy with another operation."
        case .notReady(let state):
            "The camera is not ready (\(text(for: state)))."
        }
    }

    /// The connection pill's wording for a state.
    public static func text(for state: ConnectionState) -> String {
        switch state {
        case .idle: "Not connected"
        case .awaitingAuthorization: "Waiting for camera access"
        case .unauthorized: "Camera access denied"
        case .searching: "Looking for a camera"
        case .opening: "Connecting"
        case .ready(let name): name
        case .busy(let name, let operation): "\(name): \(operation)"
        case .recovering(let name, _, _): "\(name): recovering"
        case .lost(let reason): text(for: reason)
        }
    }

    public static func text(for reason: LostReason) -> String {
        switch reason {
        case .disconnected: "Camera disconnected"
        case .sessionClosed: "Camera session closed"
        case .stalled: "Camera stopped responding"
        case .recoveryFailed: "Camera could not be recovered"
        case .openFailed: "Camera could not be opened"
        case .transportError: "Camera connection failed"
        }
    }

    // --- slot push and restore results ---

    /// Property names as the server serves them (`HighLightTone`) spaced for display.
    public static func propertyLabel(_ name: String) -> String {
        PropertyDiffRow(name: name).label
    }

    /// Short status for one slot of a collection push: "Verified", "2 settings not applied",
    /// "Not pushed \u{2014} connection lost".
    public static func text(for result: SlotPushResult) -> String {
        switch result {
        case .verified:
            "Verified"
        case .partiallyFailed(let names):
            "\(names.count) \(names.count == 1 ? "setting" : "settings") not applied"
        case .connectionLost:
            "Not pushed \u{2014} connection lost"
        }
    }

    /// The same status for VoiceOver, naming what did not take.
    public static func accessibilityText(for result: SlotPushResult) -> String {
        switch result {
        case .verified:
            "Verified"
        case .partiallyFailed(let names):
            "Did not take: \(names.map(propertyLabel).joined(separator: ", "))"
        case .connectionLost:
            "Not pushed, connection lost"
        }
    }

    // --- backup history and originals ---

    /// The badge on a slot's oldest backup.
    public static let beforeFilmcaseBadge = "Before Filmcase"

    /// The label for undoing the collection push that just ran.
    public static let undoPushLabel = "Undo this push"

    /// The label for putting every slot back as it was before Filmcase.
    public static let restoreOriginalsLabel = "Restore originals"

    public static let noOriginalsText = "There are no original backups to restore."

    /// What to ask before restoring *originals*: which slots and which names come back.
    public static func restoreOriginalsPrompt(originals: [SlotBackup]) -> String {
        guard !originals.isEmpty else { return noOriginalsText }
        let list = originals.map { "C\($0.slotIndex) \($0.slotName)" }.joined(separator: ", ")
        return "Put \(slotCountText(originals.count)) back as they were before Filmcase: \(list). "
            + "What is in them now is backed up first."
    }

    /// What happened when the originals were restored: one sentence, plus one per problem.
    public static func restoreOriginalsText(results: [Int: SlotPushResult]) -> String {
        if results.isEmpty { return noOriginalsText }
        let verified = results.values.filter { $0 == .verified }.count
        var parts = ["Restored the originals of \(slotCountText(verified))."]
        for slot in results.keys.sorted() {
            guard let result = results[slot] else { continue }
            switch result {
            case .verified: break
            case .partiallyFailed(let names):
                parts.append("C\(slot): the camera did not take \(names.joined(separator: ", ")).")
            case .connectionLost:
                parts.append("C\(slot): not restored, the camera connection was lost.")
            }
        }
        return parts.joined(separator: " ")
    }

    /// What happened when slot *slot* was restored.
    public static func restoreText(slot: Int, result: SlotPushResult) -> String {
        switch result {
        case .verified:
            "C\(slot) restored."
        case .partiallyFailed(let names):
            "C\(slot): the camera did not take \(names.joined(separator: ", "))."
        case .connectionLost:
            "The camera connection was lost."
        }
    }
}
