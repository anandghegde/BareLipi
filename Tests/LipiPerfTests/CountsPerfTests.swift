import Foundation
import LipiCore
import LipiEditor
import LipiFixtures
import XCTest

/// PRD §6.18: a 50,000-word document reports its counts in under 1 ms per
/// keystroke (per-block cache, only the edited block recounted).
@MainActor
final class CountsPerfTests: XCTestCase {
    func testCountsPerKeystrokeLorem50k() {
        let controller = EditorController(text: PerfFixture.lorem50k.text(), viewportWidth: 1200)
        var counter = DocumentCounter()
        let cold = Date()
        let total = counter.document(index: controller.blockIndex, rope: controller.rope)
        let coldMs = Date().timeIntervalSince(cold) * 1000
        XCTAssertGreaterThan(total.words, 40_000)
        controller.moveCaret(to: controller.count / 2)
        var samples: [Double] = []
        for i in 0..<Perf.scaled(400) {
            controller.insert(i % 6 == 5 ? " " : "x")
            let t = DispatchTime.now().uptimeNanoseconds
            _ = counter.document(index: controller.blockIndex, rope: controller.rope)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p99 = samples[min(samples.count - 1, samples.count * 99 / 100)]
        Perf.report("counts.lorem-50k.p50", p50, unit: "ms", budget: 1, note: "cold full count \(String(format: "%.1f", coldMs)) ms")
        Perf.report("counts.lorem-50k.p99", p99, unit: "ms", budget: 1)
    }
}
