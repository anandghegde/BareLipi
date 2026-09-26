import AppKit

/// VoiceOver rotors (§6.20): headings, links, tables, images and code
/// blocks, each stepping through the document in source order from the
/// current item (or the caret) and honouring the rotor's filter text.
extension EditorView {
    public override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [
            rotor("Headings", .heading, type: .heading),
            rotor("Links", .link, type: .link),
            rotor("Tables", .table, type: .table),
            rotor("Images", .image, type: .image),
            rotor("Code Blocks", .codeBlock, type: .any),
        ]
    }

    private func rotor(_ label: String, _ kind: NavigationKind, type: NSAccessibilityCustomRotor.RotorType) -> NSAccessibilityCustomRotor {
        let delegate = RotorSearch(view: self, kind: kind)
        let rotor: NSAccessibilityCustomRotor
        if type == .any {
            rotor = NSAccessibilityCustomRotor(label: label, itemSearchDelegate: delegate)
        } else {
            rotor = NSAccessibilityCustomRotor(rotorType: type, itemSearchDelegate: delegate)
            rotor.label = label
        }
        // The rotor holds its delegate weakly.
        objc_setAssociatedObject(rotor, &RotorSearch.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return rotor
    }

    /// The next (or previous) target of `kind` after `from` (UTF-16), whose
    /// label contains `filter`; for tests and the rotor delegate.
    public func rotorTarget(_ kind: NavigationKind, after from: NSRange?, forward: Bool, filter: String = "") -> (range: NSRange, label: String)? {
        let targets = controller.navigationTargets(kind).filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) }
        let position = from.map { controller.byteRange(fromUTF16: $0) }
        let pick: NavigationTarget?
        if let position {
            pick = forward ? targets.first { $0.range.lowerBound > position.lowerBound }
                : targets.last { $0.range.lowerBound < position.lowerBound }
        } else {
            let caret = controller.caret
            pick = forward ? targets.first { $0.range.upperBound > caret } ?? targets.first
                : targets.last { $0.range.lowerBound < caret } ?? targets.last
        }
        return pick.map { (controller.utf16Range(fromBytes: $0.range), $0.label) }
    }
}

final class RotorSearch: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    nonisolated(unsafe) weak var view: EditorView?
    let kind: NavigationKind

    init(view: EditorView, kind: NavigationKind) {
        self.view = view
        self.kind = kind
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let view else { return nil }
        let current = searchParameters.currentItem?.targetRange
        let forward = searchParameters.searchDirection == .next
        let filter = searchParameters.filterString
        let kind = kind
        let hit: (range: NSRange, label: String)? = MainActor.assumeIsolated {
            view.rotorTarget(kind, after: current, forward: forward, filter: filter)
        }
        guard let hit else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
        result.targetRange = hit.range
        result.customLabel = hit.label
        return result
    }
}
