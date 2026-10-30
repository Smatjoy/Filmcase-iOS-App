// The words a recipe row is announced with. Wording lives here (not in views) so it is tested.
//
// Unnamed recipes use the web's fallback, "<film simulation> #<id>"
// (`_RecipeCardModalContext.from_model` in src/interfaces/recipes/views.py).

import Foundation

extension RecipeSummary {
    /// The name to show: the recipe's own, or "Provia #7" when it has none.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(filmSimulation) #\(id)" : name
    }

    /// "Kodak Portra 400, Classic Chrome, favourite" (the last part only for favourites).
    public var accessibilityLabel: String {
        var parts = [displayName, filmSimulation]
        if isFavorite { parts.append("favourite") }
        return parts.joined(separator: ", ")
    }
}
