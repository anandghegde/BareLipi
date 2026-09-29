# BareLipi

ಬರೆ · ಲಿಪಿ — a native macOS Markdown editor. Swift 6, AppKit, Core Text; no web view on the editing path.

The product requirements document lives in the Claude Doc "BareLipi PRD — Native macOS Markdown Editor". Phase 0 (foundations and spikes) is complete; Phase 1, the "Bare" MVP of PRD §10, is in progress.

## Layout

| Path | What |
| --- | --- |
| `Sources/LipiCore` | Pure Swift document core: `LipiRope`, `SourceOffset`, `Edit`, `Delta`, `SourceBuffer` (undo steps carry selections), `SourceProjection` (source mode, §6.2) |
| `Sources/LipiCore/Rope` | Persistent UTF-8 B-tree rope with byte / UTF-16 / scalar / line summaries |
| `Sources/LipiCore/Parser` | `LipiParser` (value AST with byte ranges), `BlockIndex` incremental re-parse, front matter, cmark bridge |
| `Sources/LipiCore/Projection` | `Projection`: source → display blocks with `OffsetMap`s, `RevealPolicy` (PRD §6.1) |
| `Sources/CCmarkGFM` | Vendored cmark-gfm 0.29.0.gfm.13 with source-position patches and a math extension (`PATCHES.md`) |
| `Sources/CTreeSitter` | Vendored tree-sitter 0.25.10 runtime (the `lib.c` amalgamation) |
| `Sources/CTreeSitterGrammars` | The 36 Appendix A.4 grammars' generated parsers and scanners, their licences in `LICENSES/` and pinned revisions in `LICENSES/VENDORED.txt`; regenerate with `Scripts/vendor-tree-sitter.py` |
| `Sources/LipiHighlight` | Fenced-code highlighting (P0-05): `GrammarBundle` (info string → grammar), `HighlightQuery` (highlights.scm → `SyntaxToken` spans), `HighlightService` (background parse, cache, provisional spans while typing) |
| `Sources/LipiLayout` | ADR-002 block layout engine: `Typesetter` (Core Text, font cascade, themes), `BlockLayout` / `CellLayout` per block, `DocumentLayout` (lazy layout, `HeightTree`, `LayoutCache`), `CaretGeometry`, `Renderer`; `TextKit2Layout` is the headless TextKit 2 comparison used by the spike |
| `Sources/LipiEditor` | `EditorController` (PRD §7.4 keystroke pipeline over either engine, smart typing, auto-pair, typing undo coalescing, source mode), `MarkdownCommands` (§6.1.5 commands as `EditPlan`s over the block index) and `EditorView`, one layer-backed `NSView` with `NSTextInputClient`, the accessibility text protocol and the `@objc` actions behind the Format menu |
| `Sources/LipiExport` | HTML export (P0-14 Phase 1): `HTMLExporter` (cmark-gfm HTML with highlighted code, standalone page), `ExtendedSyntaxRewriter` (heading ids, `[toc]` and emoji in cmark's tree) and `ThemeCSSWriter` (theme palette, or a light / dark pair, and syntax colours as inline CSS) |
| `Sources/LipiFixtures` | Generators for the §9.1 fixture set (`lorem-50k`, `kannada-20k`, `tables-600x6`, `10mb`, `reveal-matrix`, …) and pathological inputs, deterministic from a seed |
| `Sources/LipiApp` | Application layer shared by the bundle and the executable: `LipiDocument` (ADR-008), `AtomicWriter` (§9.3 save ladder), `TextCodec` (BOM, line endings, non-UTF-8), `FileFingerprint` and `ExternalChangeMonitor`, `CaretRemap`, tabs and state restoration, `NoticeBar`, `MainMenu`, `EditorHost`, `LaunchOptions` and the `--measure` driver |
| `Sources/BareLipi` | SwiftPM executable: one window and one `EditorView` built through `LipiApp`; the harness host for `--measure` |
| `App` | The app bundle's delegate and `Info.plist` (target `BareLipiApp` in `project.yml`, `NSDocument`-based, hardened runtime) |
| `Sources/lipi-bench` | Release-mode micro-benchmarks for the core and the layout spike |
| `Sources/lipi-fixtures` | Writes the fixture set to `Fixtures/perf` as `.md` files |
| `Sources/lipi-roundtrip` | The byte-preservation check (`ByteRoundTrip`, in `LipiApp`) over any folder of Markdown or the built-in corpus |
| `Fixtures/corpus` | Small byte-exact corpus files (`-text` in `.gitattributes`); `ByteCorpus` in `LipiFixtures` adds their variants, generated edge cases, the pathological fixtures and every spec example |
| `Tests/LipiCoreTests` | swift-testing suites, including property tests against a `String` model and the parser range invariants |
| `Tests/LipiCoreTests/Fixtures` | CommonMark 0.31.2 and GFM 0.29 spec files plus the GFM extension and regression suites |
| `Tests/LipiLayoutTests` | Typesetter, block and document layout, tables, fonts, themes, code highlighting, and TextKit 2 comparison suites |
| `Tests/LipiEditorTests` | Controller and view tests: clusters, IME, motion, selection, accessibility, pixel checks, formatting commands, smart typing, auto-pair, undo coalescing, source mode |
| `Tests/LipiAppTests` | Atomic writes, text codec, external changes, restoration, document round trips and HTML export |
| `Tests/LipiCorpusTests` | The byte-preservation exit check over the corpus (about 2 min in debug) |
| `Tests/LipiPerfTests` | XCTest performance harness for the §9.1 rows with committed baselines |
| `Scripts/vendor-tree-sitter.py` | Fetches the pinned tree-sitter runtime and grammars and regenerates `Sources/CTreeSitter*` and `Sources/LipiHighlight/GrammarQueries.swift` |
| `project.yml` | xcodegen spec for the application bundle (`xcodegen generate`) |
| `.github/workflows/ci.yml` | CI: build and the whole test suite in debug on macos-latest with Xcode 26, plus an advisory release run of the gated perf harness that uploads `perf.log` |

## Build and test

```sh
swift build
swift test                                   # unit suites; perf rows print but do not gate
swift run -c release lipi-bench              # core and layout-spike micro-benchmarks
swift run -c release lipi-bench --huge [--keys N]   # keystrokes inside the 1 MB paragraph and the 256 KB line
swift run -c release lipi-bench --typing [--keys N] [--rounds R]   # EditorController keystroke → screen drawn: plain, Kannada, footnotes, emoji
swift run -c release lipi-fixtures           # writes Fixtures/perf/*.md (ignored by git)
swift run -c release lipi-roundtrip ~/Notes  # open, save, views and random edits must keep every byte; lists files that differ
swift run -c release lipi-roundtrip --corpus [--match S] [--steps N] [--no-render] -v   # the built-in corpus
swift run -c release BareLipi                # the editor with a welcome document
swift run -c release BareLipi path/to/doc.md
swift run -c release BareLipi --fixture lorem-50k --engine textkit2 --theme kari --zoom 1.2
swift run -c release BareLipi --fixture kannada-20k --measure 10   # types, scrolls, prints frame stats, quits
swift test -c release --filter LipiPerfTests                        # §9.1 harness, comparable numbers
LIPI_PERF_GATE=1 swift test -c release --filter LipiPerfTests       # fail over budget or >10 % above baseline
LIPI_PERF_RECORD=1 swift test -c release --filter LipiPerfTests     # rewrite Tests/LipiPerfTests/Baselines/m4.json
python3 Scripts/vendor-tree-sitter.py                               # re-vendor tree-sitter and the A.4 grammars (network)
xcodegen generate && open BareLipi.xcodeproj
xcodegen generate && xcodebuild -project BareLipi.xcodeproj -scheme BareLipiApp -configuration Release \
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build      # the app bundle
open DerivedData/Build/Products/Release/BareLipi.app
DerivedData/Build/Products/Release/BareLipi.app/Contents/MacOS/BareLipi --fixture kannada-20k --measure 6
```

Requires Xcode 26 / Swift 6.3 and macOS 15 or later at runtime.

## Commands and key bindings

Every menu item and editor action is a `Command` in `Sources/LipiApp/Commands/CommandRegistry.swift` (id, title, menu, default keys, action); the main menu, the editor's key table, the command palette (Cmd-Shift-P, or `>` in Quick Open) and Settings → Keys are built from it. User bindings live in `~/Library/Application Support/BareLipi/keymap.json`, loaded with the menu at launch and reloaded when the file changes; problems (bad JSON, unknown ids or presets, unparsable keys, conflicts) are logged and shown once in an alert.

```json
{ "preset": "BareLipi", "bindings": { "format.bold": "Cmd-Shift-B", "view.zoomIn": ["Cmd-=", "Cmd-+"], "file.quickOpen": null } }
```

Presets: `BareLipi` (default, PRD Appendix B) and `Typora` (Appendix B's differences). Cmd-P: the BareLipi preset keeps Cmd-P for Quick Open, and Print takes Cmd-Opt-P; the Typora preset moves Quick Open to Cmd-Shift-O so Cmd-P is free for Print, as in Typora and the HIG. Cmd-0 is both Paragraph (in the editor) and Actual Size (elsewhere) on purpose. Keys the editor handles in context (Tab and Shift-Tab in tables and lists, Opt-Return in a cell, Shift-Return, Opt-Up/Down, Esc) are listed in Settings → Keys but not rebindable yet.

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
- [x] `Projection` (PRD §6.1.1–6.1.3): per-top-level-block display blocks with entry-local `OffsetMap`s (copied / hidden / replaced segments, UTF-16 display offsets, caret resolution rules for folded markers); `RevealPolicy` implements the §6.1.2 reveal rules for the Balanced, Typora-compatible and Stable presets; entries are rebuilt only when re-parsed or when the caret's reveal set changes. Every node kind is covered by `ProjectionTests`, and the tiling / round-trip invariants (`sourceToDisplay(displayToSource(δ)) == δ`) hold over the spec suites folded, in source mode and at random carets, and across 6 × 40 random edits against a fresh projection. `lipi-bench`, release, M-series, 1 MB document:

  | Operation | Per op |
  | --- | --- |
  | Project 1 MB from scratch (1023 blocks) | 9.6 ms |
  | Caret move: reveal set + projection update | 80 µs |
  | Typing: re-parse + reveal + projection update | 145 µs |
  | Source ↔ display position lookup | 0.5 µs |
- [x] Layout spike: `LipiLayout` versus headless TextKit 2 — **ADR-002 go**. `LipiLayout` typesets each display cell with `CTTypesetter`, keeps a `HeightTree` of estimated-then-measured entry heights, caches typeset blocks by content key, and lays out only the viewport plus one screen of overscan; the font cascade (serif / sans / mono roles, per-script fallbacks, Kannada and Devanagari raised to the tall line-height class) and the four themes live beside it. `TextKit2Layout` runs the same projection through `NSTextLayoutManager` for the comparison. Both engines drive the same `EditorController`, so the go/no-go criteria were checked on both (`lipi-bench`, release, Apple M4, viewport 1000 × 800 @2×; the PRD budgets are M1 figures):

  | Fixture | Measure | `LipiLayout` | TextKit 2 |
  | --- | --- | --- | --- |
  | lorem-50k | first screen: layout + cold draw | 2.4 + 1.7 ms | 21.5 + 0.9 ms (after an 18.3 ms load) |
  | lorem-50k | keystroke → caret rect / → screen drawn | 0.21 / 0.50 ms | 2.50 / 3.56 ms |
  | lorem-50k | caret rect / hit test, random offset | 7.7 / 1.8 µs | 13.4 / 83.8 µs |
  | lorem-50k | full layout, resident added | 60 ms, +33.8 MB | 94 ms, +26.3 MB |
  | kannada-20k | keystroke → caret rect / → screen drawn | 0.53 / 1.25 ms | 1.15 / 3.99 ms |
  | kannada-20k | full layout | 110 ms | 124 ms |
  | tables-600x6 | keystroke → caret rect / → screen drawn | 3.83 / 4.14 ms | 25.2 / 27.2 ms (no table layout: cells as text) |

  Criteria: keystroke → screen for lorem-50k is 0.5 ms on M4 against the 8 ms 120 fps frame and the 3 ms §7.5 budget, with ~6× headroom for an M1; Kannada and Devanagari shape through the cascade with correct cluster caret stops and deletion (`kannadaClusterDeletionAndMotion`, `devanagariAndEmojiClusters`); IME marked text freezes the reveal set and commits in place (`markedTextRoundTrip`); VoiceOver reads the document through the accessibility text protocol (`accessibilityDescribesTheDocument`); the 600 × 6 table is a real grid island (`TableLayoutTests`) that TextKit 2 cannot lay out at all. The table keystroke is dominated by `LipiCore`, not layout: the whole table re-parses (2.1 ms) and re-projects (1.3 ms) per edit, which is a Phase 1 item (per-row table re-parse). Two findings worth keeping: `fontd` can deadlock when Core Text is first exercised from several threads at once, so `FontCascade` serialises font resolution behind a process-wide lock; and this machine's 4K display refreshes at 60 Hz, so 120 Hz criteria are stated as per-frame budgets (≤ 8.33 ms) rather than observed frame rates.
- [x] Performance harness and fixtures (PRD §9.1): `LipiFixtures` generates the fixture set deterministically (`lipi-fixtures` writes it out); `Tests/LipiPerfTests` measures every §9.1 row that exists in Phase 0 headless (an `EditorController` drawing into a 1200 × 800 @2× bitmap) and skips the rest with the reason (`XCTSkip`: pre-main, launch, keystroke → photon, math, diagrams, find, PDF, idle CPU, bundle size, baseline memory). Rows print on every run; `LIPI_PERF_GATE=1` fails a release run that is over budget or more than 10 % above `Baselines/m4.json`, `LIPI_PERF_RECORD=1` rewrites that file. Launch and frame-rate rows come from the app itself: `BareLipi --measure <s>` types and scrolls under a display link and prints process start → main, main → first frame (`launch.firstFrame` signpost), keystroke → draw work and latency, frame intervals and footprint. Building the harness fixed three things: `LayoutCache` is now bounded by lines held and keeps at most two layouts per node (typing in the 600 × 6 table used to retain one table layout per keystroke); `DocumentLayout` drops the cached layouts of node ids that a re-parse retired, since every keystroke gives the edited block fresh ids (1,000 keystrokes in a Kannada paragraph used to leave 495 stale layouts, 126 MB, in the cache; now 45 blocks); and the controller marks the caret's table grow-only so its columns never shrink mid-word. Reveal/fold compensation is the controller's `viewportShift`: the caret's line moves by up to 42 pt in document space when a fence or heading marker reveals, and the view scrolls by exactly that, so the caret's screen y is unchanged to within the clip view's pixel alignment.

  | §9.1 row | Budget (M1) | Fixture | Measured (M4) |
  | --- | --- | --- | --- |
  | Open 50k words → first frame | ≤ 60 ms | lorem-50k | 10.60 ms, +14.7 MB |
  | Open 1 MB → first frame | ≤ 80 ms | words-170k | 29.81 ms, +15.1 MB |
  | Open 20k Kannada words → first frame | ≤ 60 ms | kannada-20k | 10.37 ms |
  | Keystroke → draw, 1,000 keystrokes, p50 / p99 | ≤ 3 / 6 ms | lorem-50k | 1.11 / 1.25 ms |
  |  |  | kannada-20k | 1.76 / 2.20 ms |
  |  |  | mixed-scripts | 1.67 / 1.90 ms |
  | Typing at 120 Hz: work per frame p99, frames over 8.33 ms | ≤ 8.33 ms, 0 dropped | lorem-50k / kannada-20k / mixed-scripts | 1.16 / 1.99 / 2.17 ms, 0 dropped |
  | Scroll, one fresh screen (layout + draw), p50 / p99 | ≤ 8.33 ms | lorem-50k | 1.05 / 2.90 ms (warm draw only: 2.22 ms p99) |
  |  |  | images-200 | 0.87 / 1.19 ms |
  | Hybrid 3 MB: open / keystroke p99 / scroll p99 | 120 fps (≤ 8.33 ms) | words-500k | 83 ms / 3.40 ms / 1.68 ms |
  | Hybrid 10 MB: open / keystroke p99 / scroll p99 | 60 fps (≤ 16.7 ms) | 10mb | 252 ms (+119 MB) / 10.90 ms / 1.76 ms |
  | Reveal / fold caret y drift | ≤ 0.5 pt, every frame | reveal-matrix | 0.00 pt over 2,730 caret moves and 14 block kinds (largest line move compensated: 42 pt) |
  | Table 600 × 6 typing: p50 / p99, memory added | 120 fps, ≤ 20 MB | tables-600x6 | 4.42 / 5.51 ms, +0.02 MB |
  | Table 10k × 10 open | ≤ 500 ms | tables-10kx10 | **653 ms, +397 MB: over budget** |

  | §9.1 row | Budget (M1) | Measured (M4) |
  | --- | --- | --- |
  | Pre-main | ≤ 40 ms | 12–30 ms (the first launch of a freshly built binary pays ~550 ms in Gatekeeper's scan; excluded) |
  | Process start → first frame | ≤ 50 ms | **161–172 ms: over budget.** main → first frame is 140–152 ms = NSApplication launch and menus 68–94 ms + parse, fonts and first layout 10–22 ms + window and scroll view 30–47 ms + first draw 13–21 ms |
  | Keystroke → draw work, p50 / p99 | ≤ 3 / 6 ms | 0.5–0.6 / 0.9–2.3 ms Latin, 1.6–1.9 / 4.0–4.8 ms Kannada |
  | Frames over 1.5 × the 16.67 ms display interval while typing / scrolling (6 s each) | 0 | 0–1 / 0 in most runs (one 28 ms hitch while typing); one run had 4 while the machine was under build load |
  | Baseline memory, welcome document, idle | ≤ 80 MB | **136–157 MB: over budget.** `footprint`: 77 MB IOSurface + 51 MB graphics backing, 13 MB malloc; see below |

  Headless rows come from `swift test -c release --filter LipiPerfTests` (Apple M4, release; the budgets are the PRD's M1 figures, so an M4 should sit well inside them). App rows come from `BareLipi <fixture> --measure 6` on the second launch of the binary, with the display awake (a sleeping display stops the display link; the driver now finishes on a wall-clock deadline and says so). This machine's 4K display refreshes at 60 Hz, so the 120 fps rows are stated as per-frame budgets and the app's keystroke → drawn latency (2.7–15.8 ms p50 across runs) is the wait for the next 16.67 ms display cycle, set by where the 60 Hz keystroke timer lands, not by the editor: the work figure is the editor's. Memory deltas are process-level and noisy; the harness now prints the layout cache's size beside them, and what remains after the cache fix is Core Text's per-font shaping and glyph caches, which grow with unique text for the first tens of MB in a process (41–63 MB for Kannada, 36 MB for mixed scripts, 2.5 MB for Latin in an isolated run) before they saturate.

  Over budget, carried into Phase 1: the 10k × 10 table (the whole table is laid out at open; row-lazy table layout takes it to the same cost as any other block), launch (the SwiftPM executable's `NSApplication` bring-up and menu setup is 68–94 ms of it and window creation 30–47 ms; an app bundle with a precompiled main menu and a deferred window are the first things to try, with the editor's own share at 10–22 ms) and baseline memory (128 MB of the 157 MB footprint is layer backing on the 4K EDR display in 16-bit float, 8 bytes per pixel; 8-bit layer contents on the editor and scroll layers should halve it, and the malloc heap the editor actually owns is 13 MB).

## Phase 1 status

Phase 1 is the "Bare" MVP of PRD §10. Every item on the §10 list has now landed, P0-11 included; what remains is the short list at the end of this section and the exit checks (ten days of dogfooding, VoiceOver navigation by heading on a real run; the byte-preservation corpus is done, below). The suite is 706 swift-testing tests in 100 suites plus the 29-test XCTest harness (11 rows skip without Instruments).

- [x] Table carry-overs from Phase 0. Row-lazy table layout: a row is measured when it scrolls into view or the caret or a hit test reaches it, and carries an estimated height before that, so caret and click positions stay right; column widths are sampled and only grow; the layout cache is weighted by lines actually laid out and the renderer draws the grid for visible rows only. Per-row table re-parse: an edit inside a body row re-parses that row alone (the header, the delimiter line and the edited line are parsed on their own, checked and spliced back in), every other row keeps its id, and the entry carries a revision and a row-edit record so the projection reuses the old table and redoes just that row plus any rows the caret reveals; caret-reveal scanning now stays within the entry, which removed a whole-table shift per keystroke. Randomised tests check the invariants against a fresh full parse; none needed the rebuild fallback. `lipi-bench` and the harness, release, M4:

  | Measure | Phase 0 | Now |
  | --- | --- | --- |
  | Open 10k × 10 table (budget ≤ 500 ms) | 653 ms, +397 MB | 102 ms, +78 MB |
  | Table 600 × 6: keystroke → screen drawn (bench) | 4.27 ms (parse 2.29 + project 1.35) | 0.57 ms (parse 0.03 + project 0.08) |
  | Table 600 × 6: keystroke → caret rect (bench) | 6.10 ms | 0.22 ms |
  | `key.tables-600x6` p50 / p99, memory added (harness) | 4.42 / 5.51 ms, +0.02 MB | 0.94 / 1.06 ms, +0.00 MB |

- [x] CI and the perf gate. `.github/workflows/ci.yml` builds and runs the whole suite in debug on macos-latest with the newest Xcode 26, and a second job runs `LIPI_PERF_GATE=1` in release with `continue-on-error` (shared runners are not the baseline machine) and uploads `perf.log`; the workflow has not run on GitHub yet. `Baselines/m4.json` was re-recorded on a quiet machine with every row inside budget and 0 dropped frames. Memory rows are process-level deltas that move by tens of MB between runs of unchanged code (Core Text caches, page reclaim), so they now gate on their PRD budget only; timing rows gate at baseline + max(10 %, 1 ms), because the p99 of a 1 ms keystroke moves by a few hundred µs with machine load. With that, `LIPI_PERF_GATE=1` passes on this machine.

- [x] Editing commands and source mode (P0-01, P0-02, P1-01, P1-02, auto-pair from P0-17). Every user action becomes a list of `Edit`s applied to `SourceBuffer` as one undo step, and bytes outside the edited range never change; `MarkdownCommands` builds each change from the parsed block index as an `EditPlan` (the edits in original coordinates plus the resulting selection), uses the document's own line ending (CRLF stays CRLF) and leaves markers on untargeted nodes alone. Inline toggles expand to the word when nothing is selected. Smart Enter continues list items, task items and quote prefixes, renumbers ordered lists, and ends an empty item. Auto-pair covers `* _ ~ \` $ ( [ {` and quotes, skips code contexts, word-internal cases and escapes; typing a closer steps over its pair and Backspace removes an empty pair only if auto-pair created it. Typing undo coalesces with a 1 s gap (injectable clock); a new step starts on a pause, a change of kind, a caret jump or a space after a word. Source mode (Cmd-/) shows the bytes exactly as stored through `SourceProjection`, monospace with syntax colouring, keeping caret, selection, undo stack and the top visible line; a toggle during IME composition waits for the commit. The §6.1.4 caret boundary rule holds in hybrid mode: Right from just before a closing delimiter goes past it and folds the span, Left from just after a span goes back inside it. `EditorSettings` switches auto-pair off and sets the emphasis marker and hard-break style. `EditorView.keyEquivalents` is the one table the key handler and the app's Format menu are built from:

  | Key | Command | Key | Command |
  | --- | --- | --- | --- |
  | Cmd-/ | Source mode | Cmd-Opt-U / O / X | Bulleted / numbered / task list |
  | Cmd-B / I / E | Bold / italic / code | Cmd-Shift-Return | Toggle task done |
  | Cmd-Shift-X | Strikethrough | Cmd-] / Cmd-[ (Tab / Shift-Tab in lists) | Indent / outdent |
  | Cmd-K / Cmd-Ctrl-I | Link / image | Cmd-Opt-Q / C / B | Quote / code block / math block |
  | Cmd-1 … Cmd-6, Cmd-0 | Heading 1–6, paragraph | Cmd-Opt-- | Horizontal rule |
  | Cmd-Ctrl-= / Cmd-Ctrl-- | Promote / demote heading | Cmd-Return, Shift-Return | Exit block, hard break |

- [x] Document layer (P0-16, P0-19, ADR-008, §9.3). `LipiDocument` is an `NSDocument` with autosave in place on, draft autosave off and Versions on; Duplicate, Rename, Move, Revert and the dirty indicator are the standard machinery, and the editor keeps its own undo. Open reads through a file coordinator and records inode, mtime, size and a SHA-256, detects a BOM, CRLF / CR / LF / mixed endings and the final newline; text is kept exactly as read (CRLF, CR and NUL included), only the BOM is stripped and re-added, and save writes the exact bytes. Non-UTF-8 files open read-only with a "Convert to UTF-8" bar. `AtomicWriter` resolves symlinks (dangling ones too), writes an exclusive temp file beside the target, syncs it (full sync for Cmd-S) and swaps it in, puts back permissions, flags, creation date and xattrs without adding quarantine, writes hard links in place after a backup under `~/Library/Application Support/BareLipi/Backups/`, falls back to an in-place write on permission or cross-volume errors and refuses immutable files. External changes come from file coordination, a vnode watch and app activation, merged over 150 ms and checked against the fingerprint so the app's own saves are ignored: with no local edits the document reloads silently and keeps caret (by a line diff) and scroll; with local edits a bar offers Keep Mine, Take Theirs and Merge (P1-04): a line-based three-way merge (Myers diff, diff3) against the text last read or written, kept as a rope snapshot; a clean merge is one undo step that touches only the changed lines and keeps caret and scroll, conflicts get `<<<<<<< Mine` / `=======` / `>>>>>>> Theirs` markers in the document's line ending and a bar with the count and Next Conflict; deleted files offer Save As… and Close and autosave will not recreate them; moved files are followed. Windows prefer tabs (Cmd-T new tab, Cmd-N new window, `NewDocumentOpensInTab` swaps them) and restore caret, selection and a scroll anchor. Both hosts build the same view stack through `EditorHost`, which asks for 8-bit layer contents (AppKit backs layers on an EDR display with 16-bit float otherwise) and share the same code-built main menu. Release bundle, `--fixture kannada-20k --measure 6`, second launch onwards, 4K display at 60 Hz:

  | | Phase 0 (executable) | Now (bundle) |
  | --- | --- | --- |
  | Idle footprint, untitled document | 130 MB | 101 MB (IOSurface 26 MB, window-server graphics 49 MB, malloc 11 MB) |
  | Idle footprint, kannada-20k | 132 MB | 106 MB |
  | Pre-main | 12–30 ms | 12.5–13 ms |
  | Process start → first frame (budget ≤ 50 ms) | 161–172 ms | **149–157 ms: still over budget.** main → first frame 136–144 ms = NSApplication and NSDocumentController 76–81 ms (menu 3–6 ms) + document 1 ms + controller 14–15 ms + window 21–23 ms + first draw |
  | Keystroke → draw work, p50 / p99 (Kannada) | 1.6–1.9 / 4.0–4.8 ms | 1.6 / 3.2–3.9 ms |
  | Bundle size | — | 2.4 MB |

  Not yet: the launch budget, where most of the remaining time is AppKit's own document-controller start-up before the first document exists.

- [x] Syntax highlighting (P0-05). tree-sitter 0.25.10 and the 36 grammars of PRD A.4 are vendored under `Sources/CTreeSitterGrammars` (licences in `LICENSES`, regenerated by `Scripts/vendor-tree-sitter.py`) behind a thin Swift wrapper, `LipiHighlight`. Fences are highlighted off the main thread and cached by content; while typing, the previous spans are shifted through the edit until the new ones arrive. Fence info strings map to grammars through aliases, unknown languages stay plain, diffs use the theme's ok / error colours. Query patterns this tree-sitter cannot compile are dropped at load; a test keeps every grammar at ≥ 75 % of its patterns. `key.code-fences` is 2.4 / 4.8 ms p50 / p99 (budget 3 / 6 ms). Code blocks have a header row (language, Copy as plain text and highlighted HTML, Wrap, Lines), line numbers in a gutter inside the block, sideways scrolling that follows the caret when wrap is off, and windowed highlighting of very long fences. Wrap and Lines apply to the whole editor, not per fence. The vendored source adds ~321 MB to the working tree (~15 MB packed).

- [x] Themes (P0-15). paper / snow / ink / slate are now Taalegari, Kari, Bili and Neeli with the §8.4 palettes, `accent2`, highlight, status colours and six syntax colours each, all checked at 4.5:1 against their backgrounds. The syntax colours are our choice; Neeli's muted is #808798 to pass contrast.

- [x] HTML export (P0-14, Phase 1 part). File › Export › HTML… (Cmd-Shift-E) renders a standalone UTF-8 page off the main thread in the window's theme (inline CSS, token-coloured code, footnotes) and writes it through `AtomicWriter`; nothing is loaded from elsewhere. Math is written as MathML with the TeX alongside (no script needed; not SVG, no KaTeX option). Images are linked (paths rebased to the page's folder), copied into `<page>_files/`, or embedded, chosen in the save panel or Settings → Images; missing images are listed afterwards instead of failing the export. Headings get the editor's anchors as `id` (the same ids as the outline and `[toc]`; `{#id}` overrides, `.class` becomes `class`, and the `{…}` block is dropped), a top-level `[toc]` becomes a nested list of links, and `:emoji:` shortcodes become emoji except in code spans, code blocks, math and autolinks; sub/superscript and highlight follow View › Markdown Extensions. Theme: the window's theme, or light and dark, which keeps the window's fonts and emits its pair (Taalegari / Kari, Bili / Neeli; Increase Contrast carries over) with the dark palette under `@media screen and (prefers-color-scheme: dark)`; chosen in the save panel beside Images or in Settings → Images. Other `key=value` heading attributes are not exported.

- [x] Print and PDF export (P0-14, Phase 2 part). File › Print… (Cmd-Opt-P; Cmd-P in the Typora preset) and File › Export › PDF… paginate the HTML export's page with WebKit rather than the editor's own layout engine, since the export page already has what paper needs (images, MathML, footnotes gathered at the end, highlighted code) while the engine does not draw math yet. `PrintExport` builds the page off the main thread in the window theme's light pair (Kari prints as Taalegari, Neeli as Bili) or, by choice, the window's theme with its background edge to edge; images embedded or left out for their alt text; and print rules added: `@page` margins of 54 / 54 / 60 pt, code wrapped rather than clipped, tables unclipped, headings kept with what follows, light backgrounds printed; `WebPDFRenderer` lays it out in an offscreen `WKWebView` and paginates it with WebKit's `NSPrintOperation`, so text stays selectable. Each page gets the document title as a header and "Page N of M" as a footer, centred in the margins in the theme's muted colour and body font (`PageDecoration`), drawn as text by the print view's `drawPageBorder(with:)` (WebKit's print view is extended at run time). That view is a private WebKit class, so a macOS update can drop the header and footer without warning; `PrintDecorationTests` checks each page with PDFKit and will catch it. Print shows the standard panel as a sheet; PDF export renders on the document's paper (Page Setup), adds an outline from the headings (`PDFOutliner`, found in page order with PDFKit) and writes through `AtomicWriter` off the main thread. Settings → Print sets the images, theme, header and footer for both; the PDF save panel offers the same choices and stores them.

- [x] Find, Replace and Quick Open (P0-10). A find bar with case, whole-word, regex and source / rendered scope, a live count, Enter / Shift-Enter, Cmd-F, Cmd-Opt-F, Cmd-G, Cmd-Shift-G; visible matches are drawn by the renderer; Replace and Replace All are one undo step and leave every byte outside the matches alone. Quick Open (Cmd-P) fuzzy-matches files (open and recent documents plus Markdown files up to 3 levels under their folders, 2,000 max, until Phase 2 brings workspaces), `#` headings and `>` menu commands. The find rows run: `find.10mb` 12.5 ms (budget 20 ms), no match 6 ms, regex 53 ms, Replace All of 19k matches ≈ 0.1 s (one batched edit; was 0.72 s).

- [x] Images (P0-07). Pasted and dropped images are copied beside the document, into front matter `assets:`, else `typora-copy-images-to:` (with `${filename}`), else `./assets/`, named by timestamp and short hash (identical bytes reuse the file), TIFF → PNG and HEIC → JPEG (WebP, GIF and the rest kept as is); the link is relative and honours `typora-root-url`. Untitled documents keep images in Application Support and move them and rewrite the links on first save. Format › Image inserts a relative path. Settings → Images sets the naming, HEIC conversion, downscale on paste (a maximum width in pixels, off by default, applied to pasted and dropped images in their own format) and export image mode. Right-click an image for Zoom 25 / 33 / 50 / 67 / 100 % or Original Size: one undo step that rewrites only the image, Typora-style, as `<img src alt style="zoom:50%;" />` (an existing tag gets its zoom set and `width` / `height` dropped; Original turns a plain tag back into `![](…)`). HTML export keeps the zoom and rebases `src` wherever it sits in the tag. The editor draws a paragraph that is one image (`![alt](src "title")` or `<img>`), or an `<img>` HTML block, as an island: the path resolves beside the document or under `typora-root-url`; zoom, `width` and `height` apply, scaled down to the column with the aspect ratio kept; `ImageStore` decodes off the main thread into a bounded cache (a placeholder of estimated size meanwhile). The caret sits before or after the picture; entering it reveals the source above the picture in the link stages. Missing, undecodable and remote images show their alt text (http(s) is never fetched). Images are accessibility children labelled with their alt text. Images among text still show their alt text.

- [x] Read-only documents. `EditorController.isEditable` refuses edits up front (with a beep and the bar that explains why) for Finder-locked, unwritable and non-UTF-8 files; Cut and Paste disable. Locked files get Unlock (clears the lock and adds owner write) and Duplicate.

- [x] Editing gaps. The Cmd-K popover (AppKit, no SwiftUI) edits label, destination and title, prefills from the link under the caret or from the selection and a URL on the pasteboard, and replaces the link or selection as one undo step; an empty URL removes the link. Tables: Tab / Shift-Tab between cells, Tab in the last cell and Enter add a row, header rows complete their delimiter line, `|` and newlines in cells become `\|` and `<br>`, all as one-step `EditPlan`s. Inserted rows use the document's line ending. Esc selects the caret's block and widens on repeat, except while an input method is composing or a link or footnote popover is open (the emoji list and the find bar keep their own Esc); the block selection can be deleted, duplicated and moved.

- [x] P0-08, P0-11, P0-12, P0-13, P0-18, P0-20, checked line by line against the PRD:

  | Item | State | Left |
  | --- | --- | --- |
  | P0-08 Outline sidebar | Done: current heading, jump, drag to reorder, promote / demote, headings inside lists and quotes, front-matter title | — |
  | P0-11 Command palette, keymap | Done: see [Commands and key bindings](#commands-and-key-bindings) | Context keys (Tab in tables and lists, Esc…) listed but not rebindable; Cmd-Ctrl-1…3 sidebars wait for Phase 2 |
  | P0-12 Focus (F8), typewriter (F9), zen (Cmd-Ctrl-Shift-F) | Done: sentence or block focus, 120 ms fades (off under Reduce Motion), typewriter at 30–70 % with optional easing, padded above and below so the first and last lines reach the set position (the editor's frame and bounds start above y = 0, so document and clip coordinates are unchanged; the padding goes with the mode), zen restored on relaunch; Settings → Editing sets the focus scope, the typewriter line (slider, 5 % steps) and easing, live in open windows | — |
  | P0-13 Tasks, footnotes, front matter | Done: footnote numbering, popover, jump and return; YAML / TOML front matter (vendored Yams 6.2.2, TOMLKit 0.6.0) with malformed warnings; live `[toc]`; `{#id .class}`; emoji shortcodes and `:name` completion | Sub / superscript and highlight are opt-in under View › Markdown Extensions, not always on |
  | P0-18 Counts and status bar | Done, with Settings → Counts (reading speed, CJK by character, code, math) | — |
  | P0-20 Accessibility | Done: VoiceOver reads the projected text with heading and link attributes, islands (images, tables, code) are children, display options followed | A real VoiceOver pass for the exit check |

  Settings is an AppKit window (no SwiftUI, for launch time) with Editing, Counts, Images and Keys panes; changes apply to open windows at once.

  Launch: fonts and number formatting are warmed on a background thread while `NSApplication` starts, so main → first frame is 126–132 ms on a quiet machine (was 135). **Still over the 50 ms budget, and 50 ms is out of reach in an AppKit document app**: `NSApplication.shared` alone is 41–62 ms and pre-main ~10 ms, before any window exists. Time Profiler plus in-process marks on the release bundle (`--measure`, medians of 10 alternating runs; the machine was under heavy load, so every figure runs high): pre-main 10–16 ms, `NSApplication.shared` 41–62 ms, the code-built menu 5.6 ms, `finishLaunching` up to the untitled document 26–48 ms (AppKit's `_customizeMainMenu` adding the text-input and Writing Tools items ~6 ms, `NSDocumentController` installing Open Recent ~16 ms, mostly its first `NSButton` sizing), controller (parse, fonts, layout) 6 ms, `NSWindow` init 21–26 ms (theme frame and titlebar), the rest of the window controller ~3 ms, `showWindows` ordering front 17–27 ms, first draw 9–10 ms. Options tried: without the Open Recent submenu the total is 160.1 ms against 161.9 (within noise); ignoring saved state 159.5; no main menu at all 156.7; installing the menu after the first frame takes main → first frame from 192 to 183 ms (loaded machine) but is not landed, because `NSDocumentController` attaches the Open Recent delegate only during `finishLaunching`, so a late menu has an Open Recent that never fills. What is left is structural and risky: a plain first window shown from `applicationWillFinishLaunching` that the untitled document adopts later (it has to cooperate with state restoration and Finder open events), or dropping `NSDocument` for the first frame.

  Keystroke cost: the accessibility and syntax work had made typing 9–18 % slower (plain ~470 → ~537 µs, footnotes ~825 → ~910 µs, emoji ~500 → ~592 µs). Profiling a keystroke with `lipi-bench --typing` (an `EditorController` edit, then laying out and drawing a 1200 × 800 @2x screen as the view does) showed over half of it was redrawing the whole view, and most of that was colour emoji. Three changes won it back. A keystroke now repaints only the band of the entries it changed, a line either side, plus the old and new caret; anything that can paint elsewhere still repaints everything (selection, marked text, find, focus, typewriter, block selection, height or structure changes, viewport shifts). `PartialRedrawTests` draws random edits at 2x through the invalidated rects and compares every step with a full draw, pixel for pixel. `DocumentLayout.update` now touches only the changed entries when the document keeps its shape, instead of hashing every entry. Core Text runs carry only a CGColor, and each theme colour is made once, not converted per run on every draw. Medians of 5 alternating release runs against the previous commit, p50 per keystroke: plain 1109 → 427 µs, Kannada 1784 → 898 µs, footnotes 2714 → 1152 µs, emoji 1496 → 489 µs. The machine was loaded (load average 15–30), so the absolute figures run high and are not comparable with the earlier figures, which came from a different run; the ratios held across runs. In the app (`--measure 6`, draw work p50, 3 alternating runs): lorem-50k 0.70 → 0.48 ms, kannada-20k 1.46 → 0.91 ms. A full-screen draw pixel dump of 88 screens is unchanged. What is left: in the footnote document, `Projection.update` is now the largest part, and it is linear in the document; on plain text it is re-typesetting the caret's entry. The 1 MB paragraph is unchanged at ~13.6 ms: it is dominated by parse, projection and building the whole cell's attributed string, all linear in the block. Building that string incrementally was not attempted.

  Left in Phase 1: the launch budget (AppKit start-up alone is ~50 ms; the remaining options are structural, see Launch above); and the exit checks.

- [x] Editing inside one huge block. Breaking a cell with one `CTTypesetter` was quadratic: `CTTypesetterSuggestLineBreak` takes time in proportion to the text after the line's start, so the 1 MB paragraph took 83 s to lay out and every keystroke re-broke it. Cells of 16 K UTF-16 units or more are now broken through typesetters over 4 K windows of their text that move with the lines (a window starts at a line start and grows when a line nears its cut end), and after an edit `LayoutEngine.typeset(_:width:previous:)` keeps the lines before the edit, re-breaks from the line before it until a new line starts where an old one did past the edit, and moves the old lines after that instead of typesetting them again. Lines carry the cell offset of their `CTLine`'s index 0 (`LineFragment.base`), tops are line index × line height, decoration rects find their lines by binary search and the renderer draws only the lines in the dirty rect. Randomised tests compare the incremental layout with a fresh one (line ranges, tops, decorations, caret rects, hit tests) and windowed with single-typesetter breaks. Cells with right-to-left text keep one typesetter (a window would resolve the paragraph direction on its own). A side effect: one typesetter over more than ~10 K units stops forming emoji ZWJ sequences (👩🏽‍💻 set as two glyphs); windows keep them one glyph. `lipi-bench --huge`, release, M4, viewport 1000 × 800 @2×:

  | Block | First layout + draw | Keystroke → screen drawn (start / middle / end) |
  | --- | --- | --- |
  | 1 MB paragraph, 11,938 lines, before | 82.9 s | 98.8 s / 99.4 s / 49.2 s |
  | 1 MB paragraph, after | 216 ms | 13.8 / 13.8 / 13.0 ms |
  | 256 KB line (`long-line-256k.md`), before | 3.07 s | 3.25 s / 10.3 s / 3.05 s |
  | 256 KB line, after | 47 ms | 3.6 / 3.6 / 3.5 ms |

  Harness rows `key.paragraph-1mb` (p50 13.7 ms, p99 15.2 ms; budgets 16.7 / 25 ms) and `key.long-line-256k` (p50 4.2 ms, p99 5.2 ms; budgets 8.3 / 16.7 ms), release only. What is left of the 1 MB keystroke is linear in the block, not the line: parse 3.3 ms, reveal and projection 3.6 ms, building the attributed string about 5.5 ms, and the rest of layout plus caret (prefix / suffix compare, re-break) about 1 ms; draw 0.4 ms. An edit that changes the number of entries (Enter splitting the paragraph) gets no previous layout and can lay the block out fresh, ~200 ms at 1 MB.

- [x] Exit check: byte-preservation corpus. `ByteRoundTrip` opens each file through `LipiDocument` with its window and saves it (Cmd-S and autosave, `AtomicWriter`); projects it in hybrid mode, moves the caret, switches to source mode and back, through the four themes, zoom, contrast, widths, optional syntax, focus and typewriter, and draws it, none of which may touch the buffer; then runs 40 seeded random commands (typing, IME, paste, deletes, inline toggles, smart Enter, auto-pair, table Tab / Enter, find and Replace All in both scopes, image zoom, footnotes, block and outline moves, promote / demote) against a model that applies only the edits each change declares, and undoes every step back to the original bytes. Corpus: 1,535 files, 11 of them read-only (invalid UTF-8, Latin-1, Windows-1252, UTF-16), 1,380 of them the CommonMark, GFM and GFM extension / regression examples; BOM, CRLF, CR, mixed, no final newline, trailing whitespace, tabs, NUL, 256 KB and 100 KB lines, Kannada / Devanagari / emoji ZWJ, YAML / TOML front matter, footnotes, odd tables, HTML blocks, `[toc]`, math, Typora `<img style="zoom">`, reference links, setext, lazy continuation, mixed list markers. Release run: 60,840 edits tried (48,427 changed text), **0 files differ**. It found 10 bugs, all fixed with a regression test: toml++ aborted on a malformed date-time and on a key starting with a combining mark; word-left and Insert Footnote split a scalar (crash); Delete removed half a CRLF; cmark-gfm's table extension left the paragraph it split off without a position (crash); a NUL byte shifted every parser column after it on its line (wrong ranges; rendered find crashed); rendered Replace All rewrote `[toc]` and half of entities; outline demote of `[^1]: # T` produced overlapping edits; a command rewriting identical bytes made an empty undo step. Known, not fixed: a lone `\r` line break (classic Mac or mixed files) is not a line to editor commands, since the rope's lines end at `\n` (smart Enter writes `\n` there; other bytes are kept); a debug build overflows the main thread's stack projecting ~900 nested block quotes (release handles the 1,000 fixture); the 1 MB single paragraph, which re-typeset whole on every change (one to two minutes per edit or undo step, 3,098 s of the run), now re-breaks only the lines around the edit (see Editing inside one huge block below): `lipi-roundtrip --corpus --match paragraph-1mb` takes 7.3 s, 0 bytes differ. `LipiCorpusTests` runs the files over 64 KB lighter (decode / encode only in debug).

  Perf: after the second round of merges, `LIPI_PERF_GATE=1` (release, load average ~5) passes every row but `open.tables-10kx10`. The emoji shortcode pass had added ~20 ms to that open by copying every table cell's bytes; it now skips text without two colons, and alternating runs put it back at the pre-merge 121–125 ms. That is still above the 102 ms baseline recorded on a quiet machine, and so is the pre-merge build today, so the gate needs a run on an idle machine, then `LIPI_PERF_RECORD=1` for the new rows.

## Licence

BareLipi is released under the [MIT License](LICENSE).

`Sources/CCmarkGFM` vendors [cmark-gfm](https://github.com/github/cmark-gfm), which keeps its own licence (BSD-2-Clause for cmark, MIT for the bundled houdini and utf8proc-derived code) in `Sources/CCmarkGFM/COPYING`; BareLipi's patches to it are MIT. The spec files under `Tests/LipiCoreTests/Fixtures` are the CommonMark and GFM specifications, licensed CC-BY-SA 4.0 by their authors.

`Sources/CTreeSitter` vendors the [tree-sitter](https://github.com/tree-sitter/tree-sitter) runtime (MIT, `Sources/CTreeSitter/LICENSE`). `Sources/CTreeSitterGrammars` vendors the generated parsers, scanners and highlight queries of 36 tree-sitter grammars, each under its own licence in `Sources/CTreeSitterGrammars/LICENSES` (MIT for most, Apache-2.0 for Elixir, the Unlicense for fish), with source URLs and revisions in `LICENSES/VENDORED.txt`.
