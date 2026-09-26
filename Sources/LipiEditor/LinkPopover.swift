import AppKit
import SwiftUI

/// The Cmd-K link popover (§6.1.5, ADR-010: `NSPopover` hosting SwiftUI).
/// Label, destination and title fields; Enter commits, Esc cancels, focus
/// stays in the popover until it closes (§6.11).
@MainActor
final class LinkPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var onClose: (() -> Void)?

    init(draft: LinkDraft, commit: @escaping (LinkDraft) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let form = LinkForm(draft: draft,
                            commit: { [weak self] d in commit(d); self?.popover.performClose(nil) },
                            cancel: { [weak self] in self?.popover.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: form)
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        let done = onClose
        onClose = nil
        done?()
    }
}

struct LinkForm: View {
    enum Field: Hashable { case label, destination, title }

    @State var draft: LinkDraft
    let commit: (LinkDraft) -> Void
    let cancel: () -> Void
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Text", text: $draft.label).focused($focus, equals: .label)
                TextField("URL", text: $draft.destination, prompt: Text("https://"))
                    .focused($focus, equals: .destination)
                TextField("Title", text: $draft.title, prompt: Text("Optional"))
                    .focused($focus, equals: .title)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                if draft.isExisting {
                    Button("Remove Link") {
                        var d = draft
                        d.destination = ""
                        commit(d)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(draft.isExisting ? "Update" : "Insert") { commit(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onSubmit { commit(draft) }
        .onExitCommand(perform: cancel)
        .padding(14)
        .frame(width: 340)
        .onAppear { focus = draft.label.isEmpty ? .label : .destination }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.isExisting ? "Edit Link" : "Insert Link")
    }
}
