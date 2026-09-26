import Foundation

/// Caret blink state. The timer runs only while the view is in a window and
/// is first responder; every edit or caret move restarts the on phase.
@MainActor
final class CaretController {
    private(set) var visible = true
    var blinks = true
    var onToggle: (() -> Void)?
    private var timer: Timer?

    func restart() {
        visible = true
        guard blinks else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.visible.toggle()
                self.onToggle?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        visible = true
    }
}
