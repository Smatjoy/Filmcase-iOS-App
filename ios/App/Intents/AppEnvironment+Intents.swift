// Apple-only. Composition for intents: they run in the app's process, so they reach the one
// AppEnvironment that FilmcaseApp built at launch. No decisions live here.

import FilmcaseKit
import Foundation

extension AppEnvironment {
    /// Set once by `FilmcaseApp` at launch. Nil only if an intent runs before the app has started.
    static var shared: AppEnvironment?

    static let notReadyDialog = "Filmcase is not ready yet. Open Filmcase and try again."

    /// Run the send and return the sentence to speak.
    static func sendRecipeDialog(recipeID: Int, slot: Int) async -> String {
        guard let environment = shared else { return notReadyDialog }
        let action = SendRecipeToSlotAction(
            client: environment.client, runner: environment.connection,
            store: environment.backupStore, runtimeSource: environment.runtimeProvider,
            clock: environment.clock)
        return await action.perform(recipeID: recipeID, slot: slot).dialog
    }

    static func readSlotsDialog() async -> String {
        guard let environment = shared else { return notReadyDialog }
        let action = ReadSlotsAction(
            runner: environment.connection, runtimeSource: environment.runtimeProvider)
        return await action.perform().dialog
    }

    static func sharedRecipeLookup() -> RecipeLookup? {
        shared.map { RecipeLookup(client: $0.client) }
    }
}
