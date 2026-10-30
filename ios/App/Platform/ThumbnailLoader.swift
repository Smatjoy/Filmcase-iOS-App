// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// Thumbnails need the bearer token, so AsyncImage (plain URL loads) cannot be used: they go
// through FilmcaseClient.thumbnailData, with an in-memory NSCache in front.

import FilmcaseKit
import Foundation
import UIKit

@MainActor
final class ThumbnailLoader {
    private let client: FilmcaseClient
    // API: NSCache<KeyType, ObjectType>.countLimit / object(forKey:) / setObject(_:forKey:)
    private let cache = NSCache<NSNumber, UIImage>()

    init(client: FilmcaseClient) {
        self.client = client
        cache.countLimit = 300
    }

    /// The image for a server-relative thumbnail path such as `/api/v1/images/7/thumbnail`,
    /// or nil when it cannot be loaded (the caller shows a placeholder).
    func image(forThumbnailPath path: String) async -> UIImage? {
        guard let id = Self.imageID(in: path) else { return nil }
        let key = NSNumber(value: id)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await client.thumbnailData(imageId: id),
              let image = UIImage(data: data) // API: UIImage.init?(data:)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated static func imageID(in path: String) -> Int? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "images"), index + 1 < parts.count else { return nil }
        return Int(parts[index + 1])
    }
}
