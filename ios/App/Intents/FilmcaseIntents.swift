// Apple-only. Intents are adapters: FilmcaseKit's actions decide and write the dialog.

import AppIntents  // API: AppIntent, @Parameter, IntentResult, ProvidesDialog, IntentDialog, AppShortcutsProvider
import FilmcaseKit

struct SendRecipeToSlotIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Recipe to Camera Slot"
    static let description = IntentDescription(
        "Writes a recipe to one of the camera's custom slots. The old slot is backed up first.")
    // API: AppIntent.openAppWhenRun. ImageCaptureCore needs the app in the foreground. Used instead
    // of the iOS 26 `supportedModes` because this property exists on every OS and its spelling is certain.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Recipe")
    var recipe: RecipeEntity

    // API: @Parameter(title:inclusiveRange:) for Int
    @Parameter(title: "Slot", inclusiveRange: (1, 7))
    var slot: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$recipe) to C\(\.$slot)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // API: requestConfirmation(result:) throws if the person declines
        try await requestConfirmation(
            result: .result(
                dialog: IntentDialog(
                    stringLiteral: SendRecipeToSlotAction.overwritePrompt(recipeName: recipe.name, slot: slot))))
        let dialog = await AppEnvironment.sendRecipeDialog(recipeID: recipe.id, slot: slot)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct ReadSlotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Camera Slots"
    static let description = IntentDescription("Says what is in each of the camera's custom slots.")
    // API: AppIntent.openAppWhenRun, same reason as SendRecipeToSlotIntent (USB needs the foreground).
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await AppEnvironment.readSlotsDialog()
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct FilmcaseShortcuts: AppShortcutsProvider {
    // API: AppShortcutsProvider.appShortcuts, AppShortcut(intent:phrases:shortTitle:systemImageName:)
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendRecipeToSlotIntent(),
            phrases: ["Send a recipe to my camera with \(.applicationName)"],
            shortTitle: "Send Recipe",
            systemImageName: "camera")
        AppShortcut(
            intent: ReadSlotsIntent(),
            phrases: ["Read my camera slots in \(.applicationName)"],
            shortTitle: "Read Slots",
            systemImageName: "list.number")
    }
}
