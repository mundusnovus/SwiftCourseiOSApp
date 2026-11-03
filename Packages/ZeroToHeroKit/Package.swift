// swift-tools-version: 6.4
// ZeroToHeroKit: the course, its rules, the exercise engine and the achievements. Pure Swift, no SwiftUI, tested with
// Swift Testing. The app target owns every screen.
import PackageDescription

let package = Package(
    name: "ZeroToHeroKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "ZeroToHeroKit", targets: ["ZeroToHeroKit"]),
    ],
    targets: [
        .target(
            name: "ZeroToHeroKit",
            path: "Sources/ZeroToHeroKit",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "ZeroToHeroKitTests",
            dependencies: ["ZeroToHeroKit"],
            path: "Tests/ZeroToHeroKitTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
