import AppKit
import Testing
@testable import LipiEditor

@Suite("Emoji completion (§6.13)")
@MainActor
struct EmojiCompletionTests {
    func controller(_ text: String, caret: Int? = nil) -> EditorController {
        let c = EditorController(text: text)
        _ = c.moveCaret(to: caret ?? text.utf8.count)
        return c
    }

    @Test func detectsAColonAndTwoCharacters() {
        #expect(controller("hi :sm").emojiQuery() == EmojiQuery(range: 3..<6, text: "sm"))
        #expect(controller(":smi").emojiQuery()?.text == "smi")
        #expect(controller("(:he").emojiQuery()?.text == "he")
        #expect(controller(":smile::he").emojiQuery()?.text == "he")
        // One character is not enough.
        #expect(controller("hi :s").emojiQuery() == nil)
        // After a word character or digit.
        #expect(controller("at 12:30").emojiQuery() == nil)
        #expect(controller("http:sm").emojiQuery() == nil)
        // A finished shortcode, or no alias matching.
        #expect(controller(":smile:").emojiQuery() == nil)
        #expect(controller(":qqzzx").emojiQuery() == nil)
        // In the middle of a word.
        #expect(controller(":smile", caret: 4).emojiQuery() == nil)
        // In code, and in source mode.
        #expect(controller("a `:sm` b", caret: 6).emojiQuery() == nil)
        #expect(controller("```\n:sm\n```\n", caret: 7).emojiQuery() == nil)
        let source = controller("hi :sm")
        _ = source.setMode(.source)
        _ = source.moveCaret(to: 6)
        #expect(source.emojiQuery() == nil)
    }

    @Test func acceptingIsOneUndoStep() throws {
        let c = EditorController(text: "Hi ")
        _ = c.moveCaret(to: 3)
        for ch in [":", "s", "m", "i"] { _ = c.insert(ch) }
        let q = try #require(c.emojiQuery())
        c.acceptEmoji("smile", replacing: q)
        #expect(c.string == "Hi :smile:")
        #expect(c.caret == c.string.utf8.count)
        #expect(c.emojiQuery() == nil)
        _ = c.undo()
        #expect(c.string == "Hi :smi")
    }

    @Test func viewListsNavigatesAcceptsAndCloses() throws {
        let c = EditorController(text: "")
        let view = EditorView(controller: c, frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let here = NSRange(location: NSNotFound, length: 0)
        view.insertText(":sm", replacementRange: here)
        let names = try #require(view.emojiCompletionNames)
        #expect(names.count > 2)
        #expect(names.contains("smile"))
        #expect(view.selectedEmojiCompletion == names[0])
        #expect(view.handleEmojiCompletionKey(125))
        #expect(view.selectedEmojiCompletion == names[1])
        #expect(view.handleEmojiCompletionKey(126))
        #expect(view.handleEmojiCompletionKey(126))
        #expect(view.selectedEmojiCompletion == names.last)
        #expect(view.handleEmojiCompletionKey(125))
        #expect(view.handleEmojiCompletionKey(36))
        #expect(c.string == ":\(names[0]):")
        #expect(view.emojiCompletionNames == nil)
        #expect(!view.handleEmojiCompletionKey(36))
        // Esc closes; moving the caret away closes.
        view.insertText(" :he", replacementRange: here)
        #expect(view.emojiCompletionNames != nil)
        #expect(view.handleEmojiCompletionKey(53))
        #expect(view.emojiCompletionNames == nil)
        view.insertText("a", replacementRange: here)
        #expect(view.emojiCompletionNames != nil)
        _ = c.moveCaret(to: 0)
        #expect(view.emojiCompletionNames == nil)
    }
}
