# BareLipi

ಬರೆ · ಲಿಪಿ — a native macOS Markdown editor. Swift 6, AppKit, Core Text; no web view on the editing path.

The product requirements document lives in the Claude Doc "BareLipi PRD — Native macOS Markdown Editor". This repository is the Phase 0 implementation: foundations and spikes.

## Layout

| Path | What |
| --- | --- |
| `Sources/LipiCore` | Pure Swift document core: `LipiRope`, `SourceOffset`, `Edit`, `Delta`, `SourceBuffer` |
| `Sources/LipiCore/Rope` | Persistent UTF-8 B-tree rope with byte / UTF-16 / scalar / line summaries |
| `Sources/LipiCore/Parser` | `LipiParser` (value AST with byte ranges), `BlockIndex` incremental re-parse, front matter, cmark bridge |
| `Sources/CCmarkGFM` | Vendored cmark-gfm 0.29.0.gfm.13 with source-position patches and a math extension (`PATCHES.md`) |
| `Sources/BareLipi` | Placeholder AppKit shell (SwiftPM executable) |
| `Sources/lipi-bench` | Release-mode micro-benchmarks for the core |
| `Tests/LipiCoreTests` | swift-testing suites, including property tests against a `String` model and the parser range invariants |
| `Tests/LipiCoreTests/Fixtures` | CommonMark 0.31.2 and GFM 0.29 spec files plus the GFM extension and regression suites |
| `project.yml` | xcodegen spec for the application bundle (`xcodegen generate`) |

## Build and test

```sh
swift build
swift test
swift run -c release lipi-bench
swift run BareLipi            # placeholder window
xcodegen generate && open BareLipi.xcodeproj
```

Requires Xcode 26 / Swift 6.3 and macOS 15 or later at runtime.

## Phase 0 status

- [x] `LipiRope`: persistent rope, scalar-safe edits, O(log n) offset conversion, structural validation, property-tested on mixed-script text (Latin, Kannada, Devanagari, Tamil, CJK, Arabic, emoji ZWJ, CRLF)
- [x] `SourceBuffer`: generation counter, undo/redo with groups, O(1) snapshots
- [x] Phase 0 rope exit criterion met (`lipi-bench`, release, M-series, 1 MB mixed Latin/Kannada document):

  | Operation | Per op |
  | --- | --- |
  | Build rope from 1 MB string | 1.1 ms |
  | Insert 1 char at random offset (incl. boundary lookup) | 1.5 µs |
  | Delete 1 char at random offset | 1.2 µs |
  | Sequential typing at one caret | 1.1 µs |
  | Byte → UTF-16 / line conversions | ~0.85 µs |
  | 2 KB `string(in:)` window | 0.5 µs |
  | Snapshot | 0 ns (pointer copy) |
- [x] `LipiParser` on vendored cmark-gfm 0.29.0.gfm.13 with `BlockIndex` incremental re-parse: value AST with exact byte ranges for blocks and inlines, stable node ids across re-parses, YAML/TOML front matter, GFM tables / strikethrough / autolinks / task lists, footnotes kept in place, `$…$` math; per-parser special-character tables so parses can run concurrently (patches indexed in `Sources/CCmarkGFM/PATCHES.md`)
- [x] Phase 0 parser exit criterion met. Spec suites run through the same runner semantics as cmark-gfm's `spec_tests.py`; the incremental parser is checked against a fresh full parse after 16 × 60 random edits over random spec examples:

  | Suite | Examples | Passing |
  | --- | --- | --- |
  | CommonMark 0.31.2 | 652 | 652 |
  | GFM 0.29 spec | 670 | 670 |
  | GFM extensions | 30 | 30 |
  | GFM regression | 26 | 26 |

  `lipi-bench`, release, M-series, 1 MB document of 2 KB blocks:

  | Operation | Per op |
  | --- | --- |
  | Full parse, 200 KB (100 blocks) | 4.1 ms |
  | Full parse, 1 MB | 25.9 ms |
  | Re-parse after a 1-char insert in a random 2 KB block | 0.13 ms |
  | Re-parse while typing at one caret | 0.14 ms |
  | Re-parse after a blank line splits a block | 0.11 ms |
- [ ] Layout spike: `LipiLayout` versus headless TextKit 2 (ADR-002 go/no-go)
- [ ] Performance harness and fixtures (PRD §9.1)
