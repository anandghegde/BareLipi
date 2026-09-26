import LipiCore

/// Outline commands (§6.8): each is one undo step.
extension EditorController {
    /// The outline of the current parse.
    public func makeOutline() -> Outline { Outline(index: blockIndex, rope: rope) }

    /// Moves outline item `k`'s section before item `target` (nil: to the
    /// end). Returns false when the move is not possible.
    @discardableResult
    public func moveSection(_ outline: Outline, _ k: Int, before target: Int?) -> Bool {
        guard let plan = commands.moveSection(outline, k, before: target) else { return false }
        perform(plan)
        return true
    }

    /// Promotes (`delta` -1) or demotes (+1) outline item `k`, optionally
    /// with its subsections.
    @discardableResult
    public func shiftSection(_ outline: Outline, _ k: Int, by delta: Int, subsections: Bool = false) -> Bool {
        guard let plan = commands.shiftSection(outline, k, by: delta, subsections: subsections) else { return false }
        perform(plan)
        return true
    }
}
