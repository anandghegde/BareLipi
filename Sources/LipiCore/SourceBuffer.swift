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
        /// Selection before the step (restored by undo) and after it
        /// (restored by redo), when the caller recorded them.
        var before: UndoSelection? = nil
        var after: UndoSelection? = nil
    }

    /// A selection stored with an undo step, in source bytes.
    public struct UndoSelection: Sendable, Hashable {
        public var anchor: Int
        public var head: Int
        public init(anchor: Int, head: Int) {
            self.anchor = anchor
            self.head = head
        }
    }

    /// What one undo or redo did: the deltas in application order and the
    /// selection to restore (nil when the step recorded none).
    public struct UndoStep: Sendable {
        public var deltas: [Delta]
        public var selection: UndoSelection?
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
    /// `selection` is the selection before the group's first edit; undo
    /// restores it.
    public mutating func beginUndoGroup(selection: UndoSelection? = nil) {
        if openGroup == nil { openGroup = UndoEntry(inverse: [], forward: [], before: selection) }
    }

    /// Closes the open group. `selection` is the selection after its last
    /// edit; redo restores it.
    public mutating func endUndoGroup(selection: UndoSelection? = nil) {
        guard var group = openGroup else { return }
        openGroup = nil
        group.after = selection ?? group.after
        if !group.forward.isEmpty { undoStack.append(group) }
    }

    /// True while `beginUndoGroup` is in effect.
    public var isUndoGroupOpen: Bool { openGroup != nil }

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
    public mutating func undo() -> [Delta] { undoStep().deltas }

    /// Reverts the most recent undo step and returns the selection it
    /// recorded from before the step.
    public mutating func undoStep() -> UndoStep {
        endUndoGroup()
        guard let entry = undoStack.popLast() else { return UndoStep(deltas: [], selection: nil) }
        var deltas: [Delta] = []
        for edit in entry.inverse.reversed() {
            rope.apply(edit)
            generation &+= 1
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        redoStack.append(entry)
        return UndoStep(deltas: deltas, selection: entry.before)
    }

    @discardableResult
    public mutating func redo() -> [Delta] { redoStep().deltas }

    /// Replays the most recently undone step and returns the selection it
    /// recorded from after the step.
    public mutating func redoStep() -> UndoStep {
        guard let entry = redoStack.popLast() else { return UndoStep(deltas: [], selection: nil) }
        var deltas: [Delta] = []
        for edit in entry.forward {
            rope.apply(edit)
            generation &+= 1
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        undoStack.append(entry)
        return UndoStep(deltas: deltas, selection: entry.after)
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
