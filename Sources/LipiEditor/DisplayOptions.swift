import AppKit

/// The system accessibility display settings the editor honours (§6.20):
/// Increase Contrast switches the theme to its high-contrast token set,
/// Reduce Motion makes every transition instant, Reduce Transparency asks
/// hosts to draw opaque chrome instead of vibrancy.
public struct AccessibilityDisplayOptions: Sendable, Hashable {
    public var increaseContrast = false
    public var reduceMotion = false
    public var reduceTransparency = false

    public init(increaseContrast: Bool = false, reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    /// The settings in System Settings › Accessibility › Display.
    @MainActor
    public static var system: AccessibilityDisplayOptions {
        let ws = NSWorkspace.shared
        return AccessibilityDisplayOptions(increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast,
                                           reduceMotion: ws.accessibilityDisplayShouldReduceMotion,
                                           reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency)
    }

    /// §8.1: reveal fades, sidebar and focus transitions.
    public static let transition: TimeInterval = 0.12

    /// `duration`, or 0 under Reduce Motion.
    public func duration(_ duration: TimeInterval) -> TimeInterval { reduceMotion ? 0 : duration }

    /// Posted (object: the `EditorView`) after the view applied new options,
    /// so hosts can restyle chrome (vibrancy under Reduce Transparency).
    public static let didChange = Notification.Name("LipiAccessibilityDisplayOptionsDidChange")
}
