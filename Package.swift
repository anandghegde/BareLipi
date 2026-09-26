// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "BareLipi",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LipiCore", targets: ["LipiCore"]),
        .library(name: "LipiLayout", targets: ["LipiLayout"]),
        .library(name: "LipiEditor", targets: ["LipiEditor"]),
        .library(name: "LipiApp", targets: ["LipiApp"]),
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
        // Vendored tree-sitter 0.25.10 runtime (MIT), built from its
        // single-file amalgamation. Scripts/vendor-tree-sitter.py.
        .target(
            name: "CTreeSitter",
            exclude: ["LICENSE"],
            sources: ["src/lib.c"],
            cSettings: [
                .headerSearchPath("src"),
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DEFAULT_SOURCE"),
                .unsafeFlags(["-w"]),
            ]
        ),
        // The PRD Appendix A.4 grammars (generated parser.c + scanner.c per
        // language, licences in LICENSES/). Built optimised even in debug:
        // they are tables and hand-written scanners, never stepped through.
        .target(
            name: "CTreeSitterGrammars",
            exclude: ["LICENSES", "yaml/schema.core.c", "yaml/schema.json.c", "yaml/schema.legacy.c"],
            cSettings: [.unsafeFlags(["-w", "-Os"])]
        ),
        // Front matter parsers (§6.13), vendored and pinned: Yams 6.2.2
        // (MIT, with libyaml as CYaml) and TOMLKit 0.6.0 (MIT, a C wrapper
        // around toml++ 3, compiled as C++17; Swift sees only C).
        .target(name: "CYaml", exclude: ["LICENSE"], cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "Yams", dependencies: ["CYaml"], exclude: ["LICENSE"], cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "CTOML", exclude: ["LICENSE"], cxxSettings: [.define("TOML_EXCEPTIONS", to: "1"), .unsafeFlags(["-w"])]),
        .target(name: "TOMLKit", dependencies: ["CTOML"], exclude: ["LICENSE"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Fenced-code highlighting (P0-05, ADR-007): GrammarBundle maps info
        // strings to grammars, HighlightService parses and runs the
        // highlights query off the main thread and caches spans by content.
        .target(
            name: "LipiHighlight",
            dependencies: ["CTreeSitter", "CTreeSitterGrammars"],
            swiftSettings: strict
        ),
        // Rope, source buffer, parser, projection. Pure Swift values.
        // Front matter values are parsed with Yams and TOMLKit.
        .target(
            name: "LipiCore",
            dependencies: ["CCmarkGFM", "Yams", "TOMLKit"],
            swiftSettings: strict
        ),
        // Core Text block layout (ADR-002): font cascade, type scale,
        // typesetter, block/table layout, layout cache, height tree, and the
        // headless TextKit 2 comparison used by the layout spike.
        .target(
            name: "LipiLayout",
            dependencies: ["LipiCore", "LipiHighlight"],
            swiftSettings: strict
        ),
        // AppKit editor: EditorView (NSTextInputClient, accessibility),
        // EditorController (the §7.4 keystroke pipeline), caret and selection.
        .target(
            name: "LipiEditor",
            dependencies: ["LipiCore", "LipiHighlight", "LipiLayout"],
            swiftSettings: strict
        ),
        // Export (P0-14): standalone HTML from cmark-gfm, the highlighter
        // and the theme's CSS.
        .target(
            name: "LipiExport",
            dependencies: ["LipiCore", "LipiHighlight", "LipiLayout"],
            swiftSettings: strict
        ),
        // Deterministic generators for the §9.1 fixture set.
        .target(name: "LipiFixtures", swiftSettings: strict),
        // The application layer shared by the app bundle (App/) and the
        // SwiftPM executable: LipiDocument (ADR-008), AtomicWriter (§9.3),
        // external-change handling, windows, tabs, the main menu and the
        // launch measurement.
        .target(
            name: "LipiApp",
            dependencies: ["LipiCore", "LipiLayout", "LipiEditor", "LipiExport", "LipiFixtures"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "BareLipi",
            dependencies: ["LipiCore", "LipiLayout", "LipiEditor", "LipiFixtures", "LipiApp"],
            swiftSettings: strict
        ),
        .executableTarget(name: "lipi-bench", dependencies: ["LipiCore", "LipiLayout", "LipiFixtures"]),
        .executableTarget(name: "lipi-fixtures", dependencies: ["LipiFixtures"]),
        .testTarget(
            name: "LipiCoreTests",
            dependencies: ["LipiCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "LipiLayoutTests", dependencies: ["LipiLayout", "LipiHighlight", "LipiFixtures"]),
        .testTarget(name: "LipiEditorTests", dependencies: ["LipiEditor", "LipiHighlight", "LipiLayout", "LipiFixtures"]),
        .testTarget(
            name: "LipiAppTests",
            dependencies: ["LipiApp", "LipiCore", "LipiEditor", "LipiExport", "LipiHighlight", "LipiLayout"]
        ),
        // XCTest performance harness: one test per row of PRD §9.1.
        .testTarget(
            name: "LipiPerfTests",
            dependencies: ["LipiCore", "LipiHighlight", "LipiLayout", "LipiEditor", "LipiFixtures"],
            resources: [.copy("Baselines")]
        ),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
