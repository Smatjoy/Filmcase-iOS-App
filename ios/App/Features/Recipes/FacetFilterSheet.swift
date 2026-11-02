import FilmcaseKit
import SwiftUI

/// Facet filters from `LibraryModel.facetSections`; a tap forwards `toggleFacet`.
struct FacetFilterSheet: View {
    let library: LibraryModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.facetSections) { section in
                    Section(section.label) {
                        ForEach(section.options, id: \.value) { option in
                            optionRow(option, in: section)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { library.clearFilters() }
                        .disabled(!library.hasActiveFilters)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionRow(_ option: FacetOption, in section: FacetSection) -> some View {
        let isSelected = section.selectedValues.contains(option.value)
        return Button {
            library.toggleFacet(section.key, value: option.value)
        } label: {
            HStack {
                Text(option.label ?? option.value)
                Spacer()
                Text(option.count, format: .number).secondaryText()
                if isSelected {
                    // The selected trait below carries the state for VoiceOver.
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.accessibilityLabel)
        .disabled(!option.available)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
