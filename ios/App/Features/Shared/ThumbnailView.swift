import SwiftUI
import UIKit

/// A server thumbnail loaded with the bearer token (AsyncImage cannot send it), with the
/// shared in-memory cache. The caller sets the frame; a neutral tile shows until it loads.
struct ThumbnailView: View {
    let path: String?
    let loader: ThumbnailLoader

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: path) {
                guard let path else {
                    image = nil
                    return
                }
                image = await loader.image(forThumbnailPath: path)
            }
            .accessibilityHidden(true) // decorative: the row or title carries the name
    }
}
