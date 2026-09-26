import CoreGraphics
import Darwin
import Foundation
import LipiCore
import LipiEditor
import LipiFixtures
import LipiLayout
import XCTest

/// PRD §9.1 rows measured headless (no window): an `EditorController` drawing
/// into a 1200×800 @2× bitmap. Budgets are the PRD's M1 figures; the numbers
/// this machine produces are printed after every run and, with
/// `LIPI_PERF_RECORD=1`, written to `Baselines/m4.json`. `LIPI_PERF_GATE=1`
/// fails a row that is over budget or more than 10 % above its baseline.
/// Only a release build (`swift test -c release`) produces comparable numbers.
enum Perf {
    static let gate = ProcessInfo.processInfo.environment["LIPI_PERF_GATE"] == "1"
    static let record = ProcessInfo.processInfo.environment["LIPI_PERF_RECORD"] == "1"
    static let isRelease: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Debug builds run shorter loops: their numbers are not comparable anyway.
    static func scaled(_ n: Int) -> Int { isRelease ? n : max(50, n / 5) }

    struct Row {
        let key: String
        let value: Double
        let unit: String
        let budget: Double?
        let note: String
    }

    nonisolated(unsafe) static var rows: [Row] = []
    static let baselinePath: String = {
        let dir = (#filePath as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("Baselines/m4.json")
    }()
    static let baseline: [String: Double] = {
        guard let data = FileManager.default.contents(atPath: baselinePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? Double }
    }()

    /// Records a measurement and, when gating, asserts it against the budget
    /// and the committed baseline.
    static func report(_ key: String, _ value: Double, unit: String, budget: Double?, note: String = "",
                       file: StaticString = #filePath, line: UInt = #line) {
        rows.append(Row(key: key, value: value, unit: unit, budget: budget, note: note))
        let budgetText = budget.map { String(format: " (budget %.2f %@)", $0, unit) } ?? ""
        let baseText = baseline[key].map { String(format: " (baseline %.2f %@)", $0, unit) } ?? ""
        print(String(format: "perf %@: %.3f %@%@%@ %@", key, value, unit, budgetText, baseText, note))
        guard gate, isRelease else { return }
        if let budget { XCTAssertLessThanOrEqual(value, budget, "\(key) over PRD budget", file: file, line: line) }
        if let base = baseline[key] { XCTAssertLessThanOrEqual(value, base * 1.10, "\(key) regressed >10 % from baseline", file: file, line: line) }
    }

    static func writeBaselineIfRecording() {
        guard record else { return }
        var merged = baseline
        for row in rows { merged[row.key] = (row.value * 1000).rounded() / 1000 }
        let data = try! JSONSerialization.data(withJSONObject: merged.sorted { $0.key < $1.key }.reduce(into: [String: Double]()) { $0[$1.key] = $1.value },
                                               options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: baselinePath))
        print("perf: baseline written to \(baselinePath)")
    }

    static func printTable() {
        guard !rows.isEmpty else { return }
        print("\nperf results (\(isRelease ? "release" : "DEBUG — not comparable"), \(rows.count) rows)")
        func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, n - s.count))
            return left ? fill + s : s + fill
        }
        print("\(pad("row", 34)) \(pad("value", 12, left: true)) \(pad("unit", 6)) \(pad("budget", 10, left: true)) \(pad("baseline", 10, left: true))")
        for row in rows {
            let budget = row.budget.map { String(format: "%.2f", $0) } ?? "—"
            let base = baseline[row.key].map { String(format: "%.2f", $0) } ?? "—"
            print("\(pad(row.key, 34)) \(pad(String(format: "%.3f", row.value), 12, left: true)) \(pad(row.unit, 6)) \(pad(budget, 10, left: true)) \(pad(base, 10, left: true)) \(row.note)")
        }
        print("")
    }
}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func seconds(_ body: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
}

/// A headless screen: the editor plus a bitmap the size of a 1200×800 window
/// at 2×, drawn one viewport at a time.
@MainActor
final class Screen {
    static let size = CGSize(width: 1200, height: 800)
    let controller: EditorController
    let bitmap: CGContext

    init(_ text: String, engine: LayoutEngineKind = .lipi) {
        controller = EditorController(text: text, engine: engine, viewportWidth: Screen.size.width)
        bitmap = CGContext(data: nil, width: Int(Screen.size.width * 2), height: Int(Screen.size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        bitmap.scaleBy(x: 2, y: 2)
        bitmap.translateBy(x: 0, y: Screen.size.height)
        bitmap.scaleBy(x: 1, y: -1)
    }

    /// Lays out and draws the viewport whose top is `y`, as the view does.
    func draw(atY y: CGFloat) {
        let screen = CGRect(x: 0, y: y, width: Screen.size.width, height: Screen.size.height)
        controller.prepare(screen.insetBy(dx: 0, dy: -Screen.size.height))
        bitmap.saveGState()
        bitmap.translateBy(x: 0, y: -y)
        bitmap.setFillColor(controller.theme.colors.bg.cgColor)
        bitmap.fill(screen)
        controller.draw(in: bitmap, dirty: screen)
        bitmap.restoreGState()
    }

    /// Draws the screen around the caret.
    func drawAroundCaret(_ rect: CGRect) {
        draw(atY: max(0, (rect.midY - Screen.size.height / 2).rounded()))
    }

    /// A keystroke as the view runs it: insert, then draw the screen holding
    /// the caret. Returns the main-thread work in seconds.
    func keystroke(_ text: String) -> Double {
        seconds {
            let change = controller.insert(text)
            drawAroundCaret(change.caretRect)
        }
    }
}
