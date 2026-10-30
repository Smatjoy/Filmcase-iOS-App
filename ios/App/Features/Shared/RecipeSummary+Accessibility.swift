import FilmcaseKit

extension RecipeSummary {
    /// "Kodak Portra 400, Classic Chrome, favourite". TODO: belongs in FilmcaseKit with a test
    /// (it is wording, and wording is decided there); kept here until that package may change.
    var accessibilityDescription: String {
        isFavorite ? "\(name), \(filmSimulation), favourite" : "\(name), \(filmSimulation)"
    }
}
