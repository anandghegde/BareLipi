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
| `Sources/LipiLayout` | ADR-002 block layout engine: `Typesetter` (Core Text, font cascade, themes), `BlockLayout` / `CellLayout` per block, `DocumentLayout` (lazy layout, `HeightTree`, `LayoutCache`), `CaretGeometry`, `Renderer`; `TextKit2Layout` is the headless TextKit 2 comparison used by the spike |
| `Sources/LipiEditor` | `EditorController` (PRD §7.4 keystroke pipeline over either engine, smart typing, auto-pair, typing undo coalescing, source mode), `MarkdownCommands` (§6.1.5 commands as `EditPlan`s over the block index) and `EditorView`, one layer-backed `NSView` with `NSTextInputClient`, the accessibility text protocol and the `@objc` actions behind the Format menu |
| `Sources/LipiFixtures` | Generators for the §9.1 fixture set (`lorem-50k`, `kannada-20k`, `tables-600x6`, `10mb`, `reveal-matrix`, …) and pathological inputs, deterministic from a seed |
| `Sources/LipiApp` | Application layer shared by the bundle and the executable: `LipiDocument` (ADR-008), `AtomicWriter` (§9.3 save ladder), `TextCodec` (BOM, line endings, non-UTF-8), `FileFingerprint` and `ExternalChangeMonitor`, `CaretRemap`, tabs and state restoration, `NoticeBar`, `MainMenu`, `EditorHost`, `LaunchOptions` and the `--measure` driver |
| `Sources/BareLipi` | SwiftPM executable: one window and one `EditorView` built through `LipiApp`; the harness host for `--measure` |
| `App` | The app bundle's delegate and `Info.plist` (target `BareLipiApp` in `project.yml`, `NSDocument`-based, hardened runtime) |
| `Sources/lipi-bench` | Release-mode micro-benchmarks for the core and the layout spike |
| `Sources/lipi-fixtures` | Writes the fixture set to `Fixtures/perf` as `.md` files |
| `Tests/LipiCoreTests` | swift-testing suites, including property tests against a `String` model and the parser range invariants |
| `Tests/LipiCoreTests/Fixtures` | CommonMark 0.31.2 and GFM 0.29 spec files plus the GFM extension and regression suites |
| `Tests/LipiLayoutTests` | Typesetter, block and document layout, tables, fonts, themes, and TextKit 2 comparison suites |
| `Tests/LipiEditorTests` | Controller and view tests: clusters, IME, motion, selection, accessibility, pixel checks, formatting commands, smart typing, auto-pair, undo coalescing, source mode |
| `Tests/LipiAppTests` | Atomic writes, text codec, external changes, restoration and document round trips |
| `Tests/LipiPerfTests` | XCTest performance harness for the §9.1 rows with committed baselines |
| `project.yml` | xcodegen spec for the application bundle (`xcodegen generate`) |
| `.github/workflows/ci.yml` | CI: build and the whole test suite in debug on macos-latest with Xcode 26, plus an advisory release run of the gated perf harness that uploads `perf.log` |

## Build and test

```sh
swift build
swift test                                   # unit suites; perf rows print but do not gate
swift run -c release lipi-bench              # core and layout-spike micro-benchmarks
swift run -c release lipi-fixtures           # writes Fixtures/perf/*.md (ignored by git)
swift run -c release BareLipi                # the editor with a welcome document
swift run -c release BareLipi path/to/doc.md
swift run -c release BareLipi --fixture lorem-50k --engine textkit2 --theme kari --zoom 1.2
swift run -c release BareLipi --fixture kannada-20k --measure 10   # types, scrolls, prints frame stats, quits
swift test -c release --filter LipiPerfTests                        # §9.1 harness, comparable numbers
LIPI_PERF_GATE=1 swift test -c release --filter LipiPerfTests       # fail over budget or >10 % above baseline
LIPI_PERF_RECORD=1 swift test -c release --filter LipiPerfTests     # rewrite Tests/LipiPerfTests/Baselines/m4.json
xcodegen generate && open BareLipi.xcodeproj
xcodegen generate && xcodebuild -project BareLipi.xcodeproj -scheme BareLipiApp -configuration Release \
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build      # the app bundle
open DerivedData/Build/Products/Release/BareLipi.app
DerivedData/Build/Products/Release/BareLipi.app/Contents/MacOS/BareLipi --fixture kannada-20k --measure 6
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

Phase 1 is the "Bare" MVP of PRD §10. Three packages have landed; the rest of the §10 list (bundled grammars, paste and drop with relative paths, Quick Open and Find, the Taalegari and Kari code themes, HTML export) and the exit checks (byte-preservation corpus, ten days of dogfooding, VoiceOver navigation by heading) are not started. The suite is 272 swift-testing tests in 33 suites (`LipiCoreTests` 58, `LipiLayoutTests` 83, `LipiEditorTests` 88, `LipiAppTests` 43) plus the 24-row XCTest harness.

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

  Not yet: the Cmd-K link popover (it inserts `[label](|)` or wraps the selection; `insertLink(label:destination:title:)` is there for the UI), image insertion beyond a standard open panel (relative paths, paste and drop are P0-07), table completion, and Esc block selection.

- [x] Document layer (P0-16, P0-19, ADR-008, §9.3). `LipiDocument` is an `NSDocument` with autosave in place on, draft autosave off and Versions on; Duplicate, Rename, Move, Revert and the dirty indicator are the standard machinery, and the editor keeps its own undo. Open reads through a file coordinator and records inode, mtime, size and a SHA-256, detects a BOM, CRLF / CR / LF / mixed endings and the final newline; text is kept exactly as read (CRLF, CR and NUL included), only the BOM is stripped and re-added, and save writes the exact bytes. Non-UTF-8 files open read-only with a "Convert to UTF-8" bar. `AtomicWriter` resolves symlinks (dangling ones too), writes an exclusive temp file beside the target, syncs it (full sync for Cmd-S) and swaps it in, puts back permissions, flags, creation date and xattrs without adding quarantine, writes hard links in place after a backup under `~/Library/Application Support/BareLipi/Backups/`, falls back to an in-place write on permission or cross-volume errors and refuses immutable files. External changes come from file coordination, a vnode watch and app activation, merged over 150 ms and checked against the fingerprint so the app's own saves are ignored: with no local edits the document reloads silently and keeps caret (by a line diff) and scroll; with local edits a bar offers Keep Mine and Take Theirs (Merge is shown disabled until P1-04); deleted files offer Save As… and Close and autosave will not recreate them; moved files are followed. Windows prefer tabs (Cmd-T new tab, Cmd-N new window, `NewDocumentOpensInTab` swaps them) and restore caret, selection and a scroll anchor. Both hosts build the same view stack through `EditorHost`, which asks for 8-bit layer contents (AppKit backs layers on an EDR display with 16-bit float otherwise) and share the same code-built main menu. Release bundle, `--fixture kannada-20k --measure 6`, second launch onwards, 4K display at 60 Hz:

  | | Phase 0 (executable) | Now (bundle) |
  | --- | --- | --- |
  | Idle footprint, untitled document | 130 MB | 101 MB (IOSurface 26 MB, window-server graphics 49 MB, malloc 11 MB) |
  | Idle footprint, kannada-20k | 132 MB | 106 MB |
  | Pre-main | 12–30 ms | 12.5–13 ms |
  | Process start → first frame (budget ≤ 50 ms) | 161–172 ms | **149–157 ms: still over budget.** main → first frame 136–144 ms = NSApplication and NSDocumentController 76–81 ms (menu 3–6 ms) + document 1 ms + controller 14–15 ms + window 21–23 ms + first draw |
  | Keystroke → draw work, p50 / p99 (Kannada) | 1.6–1.9 / 4.0–4.8 ms | 1.6 / 3.2–3.9 ms |
  | Bundle size | — | 2.4 MB |

  Not yet: `EditorView` has no `isEditable`, so an edit to a read-only (non-UTF-8) document is taken back with a beep after the fact; three-way merge (P1-04); the launch budget, where most of the remaining time is AppKit's own document-controller start-up before the first document exists.

## Licence

BareLipi is released under the [MIT License](LICENSE).

`Sources/CCmarkGFM` vendors [cmark-gfm](https://github.com/github/cmark-gfm), which keeps its own licence (BSD-2-Clause for cmark, MIT for the bundled houdini and utf8proc-derived code) in `Sources/CCmarkGFM/COPYING`; BareLipi's patches to it are MIT. The spec files under `Tests/LipiCoreTests/Fixtures` are the CommonMark and GFM specifications, licensed CC-BY-SA 4.0 by their authors.
