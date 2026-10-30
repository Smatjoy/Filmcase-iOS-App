// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilmcaseKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "FilmcaseKit", targets: ["FilmcaseKit"]),
    ],
    targets: [
        .target(name: "FilmcaseKit"),
        // API/Fixtures holds recorded JSON read via #filePath, plus the Python recorder.
        .testTarget(name: "FilmcaseKitTests", dependencies: ["FilmcaseKit"], exclude: ["API/Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
