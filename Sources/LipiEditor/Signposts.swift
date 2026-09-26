import Foundation
import os

/// Instruments signposts for the two PRD §9.1 intervals the editor owns:
/// `key.toDraw` (keystroke → screen drawn) and `launch.firstFrame`.
public enum Signposts {
    public static let editor = OSSignposter(subsystem: "com.barelipi.editor", category: "editor")
    public static let launch = OSSignposter(subsystem: "com.barelipi.editor", category: "launch")
}
