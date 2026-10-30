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
        .testTarget(name: "FilmcaseKitTests", dependencies: ["FilmcaseKit"]),
    ],
    swiftLanguageModes: [.v6]
)
