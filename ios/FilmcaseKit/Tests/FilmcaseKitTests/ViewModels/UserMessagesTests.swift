import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

@Suite("UserMessages")
struct UserMessagesTests {
    private static let clientErrors: [FilmcaseClientError] = [
        .unauthorized, .serverNotConfigured, .notFound, .badRequest("nope"), .unexpectedStatus(418),
        .transport(URLError(.timedOut)), .decoding("x"), .pinMismatch(host: "h"),
        .unpinnedHost(host: "h", fingerprint: "ab"), .noReachableServer,
    ]

    @Test func everyClientErrorHasItsOwnSentence() {
        let messages = Self.clientErrors.map { UserMessages.text(for: $0) }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count, "no two errors share wording")
    }

    @Test func messagesCarryTheDetailThePersonNeeds() {
        #expect(UserMessages.text(for: FilmcaseClientError.badRequest("page_size too large")).contains("page_size too large"))
        #expect(UserMessages.text(for: FilmcaseClientError.unexpectedStatus(418)).contains("418"))
        #expect(UserMessages.text(for: FilmcaseClientError.pinMismatch(host: "filmcase.lan")).contains("filmcase.lan"))
    }

    @Test func errorsAreRoutedByType() {
        #expect(UserMessages.text(for: SlotBackupError.slotOutOfRange(slot: 9, slotCount: 7))
            == "C9 does not exist on this camera (C1 to C7).")
        #expect(UserMessages.text(for: SlotBackupError.slotOutOfRange(slot: 1, slotCount: 0))
            == "This camera has no custom slots.")
        #expect(UserMessages.text(for: SlotBackupError.wrongCamera(backup: "X-S10", connected: "X-T50"))
            == "That backup is from a X-S10, but a X-T50 is connected.")
        #expect(UserMessages.text(for: CollectionPushError.notConnected) == "No camera is connected.")
        #expect(UserMessages.text(for: CollectionPushError.duplicateSlot(2)) == "C2 is assigned twice.")
        #expect(UserMessages.text(for: ConnectionError.busy) == "The camera is busy with another operation.")
        #expect(UserMessages.text(for: RecipeWriteError(failedProperties: ["Sharpness", "Clarity"]))
            == "The camera refused: Sharpness, Clarity.")
        #expect(UserMessages.text(for: RecipeValidationError(field: "grain", value: "x")).contains("grain"))
    }

    @Test func anUnknownErrorIsAGenericSentenceNotADump() {
        struct Odd: Error {}
        #expect(UserMessages.text(for: Odd()) == "Something went wrong.")
    }

    @Test func contentStateSeparatesOfflineFromErrors() {
        #expect(ContentState.failure(FilmcaseClientError.noReachableServer) == .offline)
        #expect(ContentState.failure(FilmcaseClientError.transport(URLError(.timedOut))) == .offline)
        #expect(ContentState.failure(FilmcaseClientError.unauthorized) == .error("The server rejected the token."))
        #expect(ContentState.failure(FilmcaseClientError.decoding("x")) == .error(
            "The server sent a response the app could not read."))
    }
}
