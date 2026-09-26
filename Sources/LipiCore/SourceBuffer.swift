/// Owns the document's source rope, its generation counter and the undo
/// history. All mutation goes through `apply(_:)`, which is synchronous and
/// intended for the main thread's keystroke path. Background consumers take a
/// `snapshot()` (an O(1) copy of the rope plus its generation) and discard
/// results whose generation no longer matches.
public struct SourceBuffer: Sendable {
    public private(set) var rope: LipiRope
    public private(set) var generation: UInt64 = 0

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var openGroup: UndoEntry? = nil

    public struct Snapshot: Sendable {
        public let rope: LipiRope
        public let generation: UInt64
    }

    struct UndoEntry: Sendable {
        /// Inverse edits, applied in reverse order to undo.
        var inverse: [Edit]
        /// The forward edits, replayed in order to redo.
        var forward: [Edit]
    }

    public init(_ text: String = "") {
        rope = LipiRope(text)
    }

    public init(rope: LipiRope) {
        self.rope = rope
    }

    public func snapshot() -> Snapshot { Snapshot(rope: rope, generation: generation) }

    public var count: Int { rope.count }

    // MARK: - Editing

    /// Applies one edit and returns the delta. Records the inverse for undo,
    /// into the open group if one is open.
    @discardableResult
    public mutating func apply(_ edit: Edit) -> Delta {
        let removed = rope.string(in: edit.range)
        rope.apply(edit)
        generation &+= 1
        let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
        let inverse = Edit(range: newRange, replacement: removed)
        record(forward: edit, inverse: inverse)
        redoStack.removeAll()
        return Delta(oldRange: edit.range, newRange: newRange, generation: generation)
    }

    /// Applies several edits as one undo step. Edits are applied in order and
    /// each must be expressed in the coordinates that hold after its
    /// predecessors.
    @discardableResult
    public mutating func apply(_ edits: [Edit]) -> [Delta] {
        beginUndoGroup()
        defer { endUndoGroup() }
        return edits.map { apply($0) }
    }

    /// Starts coalescing subsequent edits into one undo step until `endUndoGroup()`.
    public mutating func beginUndoGroup() {
        if openGroup == nil { openGroup = UndoEntry(inverse: [], forward: []) }
    }

    public mutating func endUndoGroup() {
        guard let group = openGroup else { return }
        openGroup = nil
        if !group.forward.isEmpty { undoStack.append(group) }
    }

    private mutating func record(forward: Edit, inverse: Edit) {
        if openGroup != nil {
            openGroup!.forward.append(forward)
            openGroup!.inverse.append(inverse)
        } else {
            undoStack.append(UndoEntry(inverse: [inverse], forward: [forward]))
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty || !(openGroup?.forward.isEmpty ?? true) }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Reverts the most recent undo step. Returns the deltas produced.
    @discardableResult
    public mutating func undo() -> [Delta] {
        endUndoGroup()
        guard let entry = undoStack.popLast() else { return [] }
        var deltas: [Delta] = []
        for edit in entry.inverse.reversed() {
            rope.apply(edit)
            generation &+= 1
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        redoStack.append(entry)
        return deltas
    }

    @discardableResult
    public mutating func redo() -> [Delta] {
        guard let entry = redoStack.popLast() else { return [] }
        var deltas: [Delta] = []
        for edit in entry.forward {
            rope.apply(edit)
            generation &+= 1
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        undoStack.append(entry)
        return deltas
    }

    /// Replaces the whole buffer (open, revert, external reload). Clears history.
    public mutating func reset(to text: String) {
        rope = LipiRope(text)
        generation &+= 1
        undoStack.removeAll()
        redoStack.removeAll()
        openGroup = nil
    }
}
