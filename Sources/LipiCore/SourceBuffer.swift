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
        /// The step is one `applyBatch`: `forward` is disjoint edits in
        /// descending position order, so undo and redo can each replay it in
        /// one pass over the rope instead of edit by edit.
        var isBatch = false
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

    /// Applies disjoint edits, all in the current coordinates, in one pass
    /// over the rope (Replace All, multi-cursor style commands). Records them
    /// like the same edits applied one at a time from the last to the first,
    /// into the open group if one is open, so undo and redo behave the same;
    /// a step that is only this batch also undoes and redoes in one pass.
    ///
    /// Returns the deltas in descending position order: each one is valid in
    /// the coordinates its predecessors leave, as for sequential `apply`, and
    /// all of them are also valid in the coordinates from before the batch
    /// (see `LipiParser.apply(_: [Delta])`). Returns nil, changing nothing,
    /// when two edits overlap or two insertions share an offset (their order
    /// would be ambiguous).
    public mutating func applyBatch(_ edits: [Edit]) -> [Delta]? {
        let sorted = edits.sorted {
            $0.range.lowerBound.byte != $1.range.lowerBound.byte ? $0.range.lowerBound.byte < $1.range.lowerBound.byte
                : $0.range.upperBound.byte < $1.range.upperBound.byte
        }
        for k in sorted.indices.dropFirst() {
            let a = sorted[k - 1].range, b = sorted[k].range
            if b.lowerBound < a.upperBound { return nil }
            if a.isEmpty && b.isEmpty && a.lowerBound == b.lowerBound { return nil }
        }
        guard let last = sorted.last, last.range.upperBound.byte <= rope.count,
              sorted[0].range.lowerBound.byte >= 0 else { return sorted.isEmpty ? [] : nil }
        let removed = rope.applyBatch(sorted)
        generation &+= 1
        var forward: [Edit] = []
        var inverse: [Edit] = []
        var deltas: [Delta] = []
        forward.reserveCapacity(sorted.count)
        inverse.reserveCapacity(sorted.count)
        deltas.reserveCapacity(sorted.count)
        for k in sorted.indices.reversed() {
            let edit = sorted[k]
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            forward.append(edit)
            inverse.append(Edit(range: newRange, replacement: removed[k]))
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        if openGroup != nil {
            let wasEmpty = openGroup!.forward.isEmpty
            openGroup!.forward.append(contentsOf: forward)
            openGroup!.inverse.append(contentsOf: inverse)
            openGroup!.isBatch = wasEmpty
        } else {
            undoStack.append(UndoEntry(inverse: inverse, forward: forward, isBatch: true))
        }
        redoStack.removeAll()
        return deltas
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
            openGroup!.isBatch = false
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
        if entry.isBatch {
            // The inverses, replayed in reverse, run up the document; each is
            // in the coordinates the ones below it leave, so shift it back
            // into the current coordinates and apply them all in one pass.
            var shift = 0
            let current = entry.inverse.reversed().map { edit -> Edit in
                let r = edit.range.byteRange
                defer { shift += edit.insertedBytes - r.count }
                return Edit(replacing: (r.lowerBound - shift)..<(r.upperBound - shift), with: edit.replacement)
            }
            deltas = applyReplay(current)
            redoStack.append(entry)
            return UndoStep(deltas: deltas, selection: entry.before)
        }
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
        if entry.isBatch {
            // Descending and disjoint: already in the current coordinates.
            deltas = applyReplay(entry.forward.reversed())
            undoStack.append(entry)
            return UndoStep(deltas: deltas, selection: entry.after)
        }
        for edit in entry.forward {
            rope.apply(edit)
            generation &+= 1
            let newRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes)
            deltas.append(Delta(oldRange: edit.range, newRange: newRange, generation: generation))
        }
        undoStack.append(entry)
        return UndoStep(deltas: deltas, selection: entry.after)
    }

    /// Applies ascending, disjoint edits in the current coordinates in one
    /// pass without recording them; returns the deltas in descending order.
    private mutating func applyReplay(_ ascending: [Edit]) -> [Delta] {
        _ = rope.applyBatch(ascending)
        generation &+= 1
        return ascending.reversed().map { edit in
            Delta(oldRange: edit.range,
                  newRange: edit.range.lowerBound..<(edit.range.lowerBound + edit.insertedBytes),
                  generation: generation)
        }
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
