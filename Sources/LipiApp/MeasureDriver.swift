import AppKit
import LipiEditor
import LipiFixtures

/// `--measure <seconds>`: types into the editor for the first half of the
/// time and scrolls it for the second half, sampling frame intervals with
/// the view's display link and keystroke → draw from the view, then prints
/// the report and quits. Keystrokes go through `insertText` (the
/// `NSTextInputClient` path), so event dispatch is not included.
/// Where launch time goes, all in seconds. `appLaunch` is `main` →
/// `applicationDidFinishLaunching` (NSApplication and menu setup),
/// `controller` is parse + projection + font cascade + first layout,
/// `window` is window/scroll view creation up to `orderFront`, and
/// `firstDraw` is from there to the end of the first `draw(_:)`.
public struct LaunchPhases {
    public var appLaunch: Double
    public var documentLoad: Double = 0
    public var controller: Double = 0
    public var window: Double = 0
    public var shown: Double = 0
    public var firstDraw: Double = 0
    public var mainToFirstFrame: Double = 0
    public var preMain: Double?
    public var toFirstFrame: Double?
    /// Main menu construction, part of `appLaunch` (zero when the menu comes from a nib).
    public var menu: Double = 0

    public init(appLaunch: Double) { self.appLaunch = appLaunch }
}

@MainActor
public final class MeasureDriver: NSObject {
    private let view: EditorView
    private let seconds: Double
    private var displayLink: CADisplayLink?
    private var keyTimer: Timer?
    private var deadline: Timer?
    private var timedOut = false
    private var frameTimestamps: [Double] = []
    private var phase = "typing"
    private var typingFrames = 0
    private var scrollingFrames = 0
    private var rng = SplitMix64(seed: 11)
    private var started: Double = 0
    private var scrollDirection: CGFloat = 1
    private var keystrokesAtStart = 0
    private let launch: LaunchPhases
    /// Which host printed the report: "executable" (SwiftPM) or "bundle".
    public static var host = "executable"

    public init(view: EditorView, seconds: Double, launch: LaunchPhases) {
        self.view = view
        self.seconds = seconds
        self.launch = launch
    }

    public func start() {
        started = CACurrentMediaTime()
        keystrokesAtStart = view.keystrokeToDraw.count
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Put the caret in the middle of the document, inside a paragraph.
        let middle = view.controller.count / 2
        view.controller.moveCaret(to: middle)
        keyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.type() }
        }
        RunLoop.main.add(keyTimer!, forMode: .common)
        // The display link only fires while the display is awake; finish on
        // a wall-clock deadline as well so a sleeping display cannot hang
        // the run, and say so in the report.
        deadline = Timer.scheduledTimer(withTimeInterval: seconds + 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != "done" else { return }
                self.timedOut = true
                self.finish()
            }
        }
    }

    private func type() {
        guard phase == "typing" else { return }
        let words = Words.latin
        let word = rng.pick(words)
        let text = rng.chance(0.15) ? " " : String(word[word.index(word.startIndex, offsetBy: rng.below(word.count))])
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        frameTimestamps.append(now)
        let elapsed = now - started
        if phase == "typing" {
            typingFrames += 1
            if elapsed >= seconds / 2 {
                phase = "scrolling"
                keyTimer?.invalidate()
                view.controller.moveCaret(to: 0)
            }
        } else if phase == "scrolling" {
            scrollingFrames += 1
            guard let clip = view.enclosingScrollView?.contentView else { return }
            var origin = clip.bounds.origin
            let maxY = max(0, view.frame.height - clip.bounds.height)
            origin.y += scrollDirection * clip.bounds.height / 8
            if origin.y >= maxY { origin.y = maxY; scrollDirection = -1 }
            if origin.y <= 0 { origin.y = 0; scrollDirection = 1 }
            clip.scroll(to: origin)
            view.enclosingScrollView?.reflectScrolledClipView(clip)
            if elapsed >= seconds { finish() }
        }
    }

    private func finish() {
        phase = "done"
        displayLink?.invalidate()
        keyTimer?.invalidate()
        deadline?.invalidate()
        let nominal = 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let intervals = zip(frameTimestamps, frameTimestamps.dropFirst()).map { $1 - $0 }
        let typing = Array(intervals.prefix(max(0, typingFrames - 1))).sorted()
        let scrolling = Array(intervals.dropFirst(max(0, typingFrames - 1))).sorted()
        let keys = Array(view.keystrokeToDraw.dropFirst(keystrokesAtStart)).sorted()
        let work = Array(view.keystrokeWork.dropFirst(keystrokesAtStart)).sorted()
        func line(_ name: String, _ samples: [Double]) -> String {
            guard !samples.isEmpty else { return "  \(name): no samples" }
            let dropped = samples.filter { $0 > nominal * 1.5 }.count
            return "  \(name): \(samples.count) frames, interval p50 \(ms(percentile(samples, 0.5))), p99 \(ms(percentile(samples, 0.99))), max \(ms(samples.last!)), "
                + "over 1.5× nominal: \(dropped)"
        }
        var report = "BareLipi --measure (\(MeasureDriver.host), \(view.controller.engine.rawValue) engine, \(Int(seconds)) s, display \(Int(1 / nominal)) Hz, \(view.controller.count) bytes)\n"
        if timedOut {
            report += "  WARNING: the display link fired \(frameTimestamps.count) times in \(Int(seconds + 3)) s; is the display asleep? Frame figures are unreliable.\n"
        }
        if let preMain = launch.preMain { report += "  process start → main: \(ms(preMain))\n" }
        report += "  main → first frame: \(ms(launch.mainToFirstFrame)) = app launch \(ms(launch.appLaunch)) (menu \(ms(launch.menu)))"
            + " + document load \(ms(launch.documentLoad)) + controller (parse, fonts, layout) \(ms(launch.controller))"
            + " + window \(ms(launch.window)) + first draw \(ms(launch.firstDraw))\n"
        if let total = launch.toFirstFrame { report += "  process start → first frame: \(ms(total))\n" }
        report += "  keystroke → draw work (pipeline + draw): \(work.count) keystrokes, p50 \(ms(percentile(work, 0.5))), p99 \(ms(percentile(work, 0.99))), max \(ms(work.last ?? 0))\n"
        report += "  keystroke → drawn latency (incl. display cycle wait): p50 \(ms(percentile(keys, 0.5))), p99 \(ms(percentile(keys, 0.99))), max \(ms(keys.last ?? 0))\n"
        report += line("typing", typing) + "\n"
        report += line("scrolling", scrolling) + "\n"
        report += "  resident: \(residentMB()) MB\n"
        print(report, terminator: "")
        fflush(stdout)
        // Exit rather than terminate: in the bundle the typed text leaves an
        // edited untitled document, and terminate would wait on its save sheet.
        exit(0)
    }

    private func residentMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }
}
