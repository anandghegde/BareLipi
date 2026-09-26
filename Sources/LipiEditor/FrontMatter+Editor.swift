import LipiCore

extension EditorController {
    /// Re-parses the front matter when entry 0 changed (a few comparisons
    /// otherwise), and shows malformed front matter as source with a warning.
    func updateFrontMatter() {
        let index = blockIndex
        guard let first = index.entries.first, first.block.kind.isFrontMatter else {
            frontMatter = nil
            frontMatterKey = nil
            projection.frontMatterWarning = nil
            return
        }
        let key = (id: first.block.id, revision: first.revision, length: first.length)
        if let old = frontMatterKey, old.id == key.id, old.revision == key.revision, old.length == key.length { return }
        frontMatterKey = key
        frontMatter = FrontMatterData.parse(index: index, rope: rope)
        projection.frontMatterWarning = frontMatter?.error
    }

    /// The document title for the outline: the front matter `title`.
    public var documentTitle: String? { frontMatter?.title }
}
