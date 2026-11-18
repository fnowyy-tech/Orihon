// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mihon-iOS",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MihonDomain",
            targets: ["MihonDomain"]
        ),
        .library(
            name: "MihonAPKEngine",
            targets: ["MihonAPKEngine"]
        ),
        .library(
            name: "MihonData",
            targets: ["MihonData"]
        ),
        .library(
            name: "MihonPresentation",
            targets: ["MihonPresentation"]
        ),
        .executable(
            name: "MihonApp",
            targets: ["MihonApp"]
        )
    ],
    targets: [
        .target(
            name: "MihonDomain",
            dependencies: [],
            path: "Sources/MihonDomain"
        ),
        .target(
            name: "MihonAPKEngine",
            dependencies: ["MihonDomain"],
            path: "Sources/MihonAPKEngine"
        ),
        .target(
            name: "MihonData",
            dependencies: ["MihonDomain", "MihonAPKEngine"],
            path: "Sources/MihonData"
        ),
        .target(
            name: "MihonPresentation",
            dependencies: ["MihonDomain", "MihonAPKEngine", "MihonData"],
            path: "Sources/MihonPresentation"
        ),
        .executableTarget(
            name: "MihonApp",
            dependencies: ["MihonDomain", "MihonAPKEngine", "MihonData", "MihonPresentation"],
            path: "Sources/MihonApp"
        ),
        .testTarget(
            name: "MihonTests",
            dependencies: ["MihonDomain", "MihonAPKEngine", "MihonData", "MihonPresentation"],
            path: "Tests/MihonTests",
            // Recorded source API responses (offline parsing tests).
            resources: [.copy("Fixtures")]
        )
    ]
)
