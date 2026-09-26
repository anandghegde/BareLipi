// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BareLipi",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LipiCore", targets: ["LipiCore"]),
        .executable(name: "BareLipi", targets: ["BareLipi"]),
    ],
    targets: [
        // Vendored cmark-gfm 0.29.0.gfm.13 with BareLipi's source-position
        // patches and the inline-math extension. See Sources/CCmarkGFM/PATCHES.md.
        .target(
            name: "CCmarkGFM",
            exclude: ["COPYING", "PATCHES.md"],
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("extensions"),
            ]
        ),
        .target(
            name: "LipiCore",
            dependencies: ["CCmarkGFM"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "BareLipi",
            dependencies: ["LipiCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(name: "lipi-bench", dependencies: ["LipiCore"]),
        .testTarget(
            name: "LipiCoreTests",
            dependencies: ["LipiCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .c99
)
