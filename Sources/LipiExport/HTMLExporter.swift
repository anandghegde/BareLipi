import Foundation
import LipiCore
import LipiHighlight
import LipiLayout

/// Standalone HTML export (P0-14, Phase 1): cmark-gfm's HTML for the
/// document, fenced code coloured by the tree-sitter highlighter, and the
/// theme as inline CSS. The file loads nothing from elsewhere; only the
/// document's own image and link targets point outside it.
public struct HTMLExporter: Sendable {
    public var theme: Theme
    /// Colours fenced code; `nil` exports code uncoloured.
    public var highlighter: HighlightService?

    /// GFM, footnotes and math, as the editor parses; footnotes are
    /// numbered and gathered at the end, as a reader expects.
    public static let parserOptions = ParserOptions(extensions: [.gfm, .footnotes, .math])

    public init(theme: Theme = .taalegari, highlighter: HighlightService? = .shared) {
        self.theme = theme
        self.highlighter = highlighter
    }

    /// The complete document.
    public func document(markdown: String, title: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="BareLipi">
        <title>\(HTMLEscaping.escape(title))</title>
        <style>
        \(ThemeCSSWriter(theme: theme).css())
        </style>
        </head>
        <body>
        <main class="lipi-document">
        \(body(markdown: markdown))</main>
        </body>
        </html>

        """
    }

    /// The document as UTF-8 bytes.
    public func data(markdown: String, title: String) -> Data {
        Data(document(markdown: markdown, title: title).utf8)
    }

    /// The rendered body: cmark-gfm HTML with fenced code highlighted.
    public func body(markdown: String) -> String {
        let html = LipiParser.renderHTML(markdown, options: HTMLExporter.parserOptions)
        guard let highlighter else { return html }
        return HTMLExporter.highlightCodeBlocks(in: html, highlighter: highlighter)
    }

    /// Rewrites each `<pre><code class="language-x">…</code></pre>` whose
    /// language the bundle knows, wrapping tokens in `<span class="tok-*">`.
    static func highlightCodeBlocks(in html: String, highlighter: HighlightService) -> String {
        let open = "<pre><code class=\"language-"
        var out = ""
        out.reserveCapacity(html.utf8.count + html.utf8.count / 4)
        var rest = html[...]
        while let start = rest.range(of: open) {
            out += rest[..<start.lowerBound]
            let afterOpen = rest[start.upperBound...]
            guard let quote = afterOpen.firstIndex(of: "\""),
                  let tagEnd = afterOpen[quote...].firstIndex(of: ">"),
                  let close = afterOpen[tagEnd...].range(of: "</code></pre>")
            else {
                out += rest[start.lowerBound...]
                return out
            }
            let language = HTMLEscaping.unescape(String(afterOpen[..<quote]))
            let escapedCode = afterOpen[afterOpen.index(after: tagEnd)..<close.lowerBound]
            out += rest[start.lowerBound...tagEnd]
            if let grammar = GrammarBundle.grammar(forInfo: language) {
                let code = HTMLEscaping.unescape(String(escapedCode))
                out += markup(code: code, spans: highlighter.highlight(code: code, grammar: grammar))
            } else {
                out += escapedCode
            }
            out += "</code></pre>"
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    /// `code` escaped, with the spans (sorted, non-overlapping UTF-16
    /// ranges) wrapped in their token classes.
    static func markup(code: String, spans: [HighlightSpan]) -> String {
        let units = Array(code.utf16)
        var out = ""
        var at = 0
        func text(_ range: Range<Int>) -> String {
            HTMLEscaping.escape(String(decoding: units[range], as: UTF16.self))
        }
        for span in spans {
            let lower = max(span.range.lowerBound, at), upper = min(span.range.upperBound, units.count)
            guard lower < upper else { continue }
            if at < lower { out += text(at..<lower) }
            out += "<span class=\"\(span.token.cssClass)\">\(text(lower..<upper))</span>"
            at = upper
        }
        if at < units.count { out += text(at..<units.count) }
        return out
    }
}

/// HTML text escaping as cmark-gfm does it (`&`, `<`, `>`, `"`).
enum HTMLEscaping {
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Inverse of `escape` (`&amp;` last, so `&amp;lt;` becomes `&lt;`).
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
