import AppKit
import Foundation
import LipiApp
import LipiFixtures

// The byte-preservation check (ByteRoundTrip) over a folder of Markdown:
//
//   swift run lipi-roundtrip <dir> [--steps N] [--seed N] [--no-edits] [--no-render]
//   swift run lipi-roundtrip --corpus [--match S]   (the built-in corpus, or
//                                                    the files whose name has S)
//
// Files are only read; checks run on copies in a temporary directory.
// Prints every file whose bytes differ and exits 1 if any did.

setvbuf(stdout, nil, _IOLBF, 0)
let usage = "usage: lipi-roundtrip <dir|file>... [--steps N] [--seed N] [--no-edits] [--no-render] [--corpus] [--match S] [--verbose]"
var roots: [URL] = []
var options = ByteRoundTrip.Options()
var useCorpus = false
var match: String?
var verbose = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--steps": options.steps = args.next().flatMap(Int.init) ?? options.steps
    case "--seed": options.seed = args.next().flatMap(UInt64.init) ?? options.seed
    case "--no-edits": options.steps = 0
    case "--no-render": options.render = false
    case "--corpus": useCorpus = true
    case "--match": match = args.next()
    case "--verbose", "-v": verbose = true
    case "-h", "--help": print(usage); exit(0)
    default: roots.append(URL(fileURLWithPath: arg))
    }
}
guard useCorpus || !roots.isEmpty else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

/// Every .md / .markdown / .mdown / .mkd file under `roots`.
func markdownFiles(_ roots: [URL]) -> [URL] {
    let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt"]
    var out: [URL] = []
    for root in roots {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("no such file: \(root.path)\n".utf8))
            continue
        }
        if !isDirectory.boolValue { out.append(root); continue }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if extensions.contains(url.pathExtension.lowercased()) { out.append(url) }
        }
    }
    return out.sorted { $0.path < $1.path }
}

let exitCode: Int32 = MainActor.assumeIsolated {
    _ = NSApplication.shared
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-roundtrip-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    var inputs: [(String, () -> Data?)] = []
    if useCorpus {
        for file in (try? ByteCorpus.all()) ?? [] where match.map(file.name.contains) ?? true {
            inputs.append((file.name, { file.data }))
        }
    }
    for url in markdownFiles(roots) { inputs.append((url.path, { try? Data(contentsOf: url) })) }

    let start = Date()
    var failed = 0, readOnly = 0, tried = 0, applied = 0, known = 0
    for (name, load) in inputs {
        guard let data = load() else {
            print("UNREADABLE  \(name)")
            failed += 1
            continue
        }
        let fileStart = Date()
        let report = autoreleasepool { ByteRoundTrip.check(name: name, data: data, options: options, scratch: scratch) }
        let seconds = String(format: "%.1f s", Date().timeIntervalSince(fileStart))
        tried += report.editsTried
        applied += report.editsApplied
        if report.readOnly { readOnly += 1 }
        known += report.known.count
        if report.passed {
            if verbose { print("ok          \(name)\(report.readOnly ? " (read-only)" : "") \(seconds)") }
            if verbose { for k in report.known { print("            known: \(k)") } }
        } else {
            failed += 1
            print("DIFFERS     \(name)")
            for failure in report.failures { print("            \(failure)") }
        }
    }
    print(String(format: "%d files (%d read-only), %d edits tried (%d changed text), %d differ, %d known lone-CR issues, %.1f s",
                 inputs.count, readOnly, tried, applied, failed, known, Date().timeIntervalSince(start)))
    return failed == 0 ? 0 : 1
}
exit(exitCode)
