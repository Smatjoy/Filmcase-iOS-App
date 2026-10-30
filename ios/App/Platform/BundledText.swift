// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import Foundation

enum BundledText {
    /// The contents of a bundled `.txt` resource, or a plain note when it is missing.
    static func load(_ name: String, bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "\(name) is not bundled with this build." }
        return text
    }
}
