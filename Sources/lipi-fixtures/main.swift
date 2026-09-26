import Foundation
import LipiFixtures

// Writes the §9.1 fixture set to Fixtures/perf (or the directory given).
let directory = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : Fixtures.defaultDirectory
let start = Date()
let written = try Fixtures.write(to: directory)
var total = 0
for url in written {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    total += size
    print(String(format: "%10d  %@", size, url.lastPathComponent))
}
print(String(format: "%d files, %.1f MB, %.2f s → %@", written.count, Double(total) / 1_048_576, Date().timeIntervalSince(start), directory.path))
