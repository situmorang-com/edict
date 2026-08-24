// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Edict",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Edict", targets: ["Edict"]),
        .library(name: "EdictKit", targets: ["EdictKit"]),
    ],
    targets: [
        // Thin launcher. Everything real lives in EdictKit so it can be unit tested.
        .executableTarget(
            name: "Edict",
            dependencies: ["EdictKit"],
            path: "Sources/Edict"
        ),
        .target(
            name: "EdictKit",
            path: "Sources/EdictKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EdictKitTests",
            dependencies: ["EdictKit"],
            path: "Tests/EdictKitTests"
        ),
    ]
)
