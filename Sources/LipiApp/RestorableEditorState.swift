import Foundation

/// The editor state `NSDocument` restoration carries across relaunches
/// (§6.19): selection and a scroll anchor. The anchor is a source offset on
/// the top line of the viewport plus the distance of the viewport's top
/// below that line's top, so it survives layout changes (a different window
/// width, estimated heights) better than a raw y. Mode, reveal preset and
/// sidebar flags join this struct when those features exist.
public struct RestorableEditorState: Codable, Sendable, Equatable {
    /// Bumped when fields change meaning; unknown versions are ignored.
    public static let currentVersion = 1
    static let coderKey = "BareLipi.editorState"

    public var version: Int = RestorableEditorState.currentVersion
    /// Selection anchor, source bytes.
    public var anchor: Int
    /// Selection head (the caret), source bytes.
    public var head: Int
    /// Source offset at the top of the viewport.
    public var scrollAnchor: Int
    /// Points from the top of `scrollAnchor`'s line to the top of the viewport.
    public var scrollOffset: Double
    /// The outline sidebar is open (§6.8); nil in state from older builds.
    public var showsOutline: Bool?

    public init(anchor: Int, head: Int, scrollAnchor: Int, scrollOffset: Double) {
        self.anchor = anchor
        self.head = head
        self.scrollAnchor = scrollAnchor
        self.scrollOffset = scrollOffset
    }

    /// Stores the state in a restoration coder as JSON.
    public func encode(to coder: NSCoder) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        coder.encode(data as NSData, forKey: RestorableEditorState.coderKey)
    }

    /// Reads the state back; nil when absent, malformed or from a newer version.
    public static func decode(from coder: NSCoder) -> RestorableEditorState? {
        guard let data = coder.decodeObject(of: NSData.self, forKey: coderKey) as Data?,
              let state = try? JSONDecoder().decode(RestorableEditorState.self, from: data),
              state.version <= currentVersion else { return nil }
        return state
    }

    /// Clamps every offset into a document of `count` bytes (the file may
    /// have changed while the app was not running).
    public func clamped(to count: Int) -> RestorableEditorState {
        func c(_ v: Int) -> Int { max(0, min(v, count)) }
        var copy = self
        copy.anchor = c(anchor)
        copy.head = c(head)
        copy.scrollAnchor = c(scrollAnchor)
        return copy
    }
}
