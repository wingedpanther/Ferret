// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ferret",
    platforms: [.macOS(.v14)],
    targets: [
        // Talks to the fsearch daemon over its JSON-lines socket. No UI, so it is testable on its own.
        .target(name: "FSearchKit"),
        // The menu-bar app. scripts/bundle.sh wraps it in Ferret.app with Resources/.
        .executableTarget(name: "Ferret", dependencies: ["FSearchKit"]),
        .testTarget(name: "FSearchKitTests", dependencies: ["FSearchKit"]),
        .testTarget(name: "FerretTests", dependencies: ["Ferret"]),
    ],
    swiftLanguageModes: [.v5]
)
