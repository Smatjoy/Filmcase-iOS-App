// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// The last served `/camera/client-config.json` body, kept in Application Support so the
/// camera works offline with what the server last said. Decoding and fallback are
/// FilmcaseKit's (`loadClientConfig`); this only reads and writes the bytes.
struct FileClientConfigCache: ClientConfigCache {
    let url: URL

    /// `Application Support/camera_client_config.json`.
    static func standard() -> FileClientConfigCache {
        // API: URL.applicationSupportDirectory (iOS 16+), URL.appending(path:)
        FileClientConfigCache(url: URL.applicationSupportDirectory.appending(path: "camera_client_config.json"))
    }

    func load() async -> Data? {
        try? Data(contentsOf: url)
    }

    func store(_ data: Data) async {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
