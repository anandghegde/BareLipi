import Foundation

/// A small TeX-to-MathML translator for HTML export (§6.4 Export, §6.14):
/// the common LaTeX math subset (scripts, fractions, roots, Greek, operators,
/// functions, accents, fonts, `\left…\right`, matrices, cases and aligned
/// environments). Commands it does not know become `<merror>` naming the
/// command, and the TeX source always travels with the formula in
/// `data-tex` and an `<annotation>`, so nothing is lost.
public enum TeXToMathML {
    /// `<math>` for `tex`, with the source as an annotation.
    public static func math(_ tex: String, display: Bool) -> String {
        var parser = Parser(tokens: tokenize(tex))
        let body = parser.parseRow(until: [])
        let escaped = escape(tex)
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display ? "block" : "inline")\">"
            + "<semantics><mrow>\(body)</mrow><annotation encoding=\"application/x-tex\">\(escaped)</annotation></semantics></math>"
    }

    /// Commands the translator rendered as errors (for the export report).
    public static func unsupportedCommands(in tex: String) -> [String] {
        var parser = Parser(tokens: tokenize(tex))
        _ = parser.parseRow(until: [])
        return parser.unsupported
    }

    // MARK: Tokens

    enum Token: Equatable {
        case command(String)
        case letter(Character)
        case number(String)
        case symbol(Character)
        case open, close, sup, sub, align, space
    }

    static func tokenize(_ tex: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(tex)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 1
                guard i < chars.count else { tokens.append(.symbol("\\")); break }
                if chars[i].isASCII, chars[i].isLetter {
                    var name = ""
                    while i < chars.count, chars[i].isASCII, chars[i].isLetter { name.append(chars[i]); i += 1 }
                    tokens.append(.command(name))
                    continue
                }
                tokens.append(.command(String(chars[i])))
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "^": tokens.append(.sup)
            case "_": tokens.append(.sub)
            case "&": tokens.append(.align)
            case "%":
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            case _ where c.isWhitespace:
                if tokens.last != .space { tokens.append(.space) }
            case _ where c.isASCII && c.isNumber:
                var number = ""
                while i < chars.count, chars[i].isASCII,
                      chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                    number.append(chars[i]); i += 1
                }
                tokens.append(.number(number))
                continue
            case _ where c.isLetter: tokens.append(.letter(c))
            default: tokens.append(.symbol(c))
            }
            i += 1
        }
        return tokens
    }

    // MARK: Tables

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς",
        "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    /// Ordinary symbols (identifiers).
    static let identifiers: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "imath": "ı", "jmath": "ȷ", "top": "⊤", "bot": "⊥",
    ]

    static let operators: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅", "div": "÷", "ast": "∗", "star": "⋆", "circ": "∘",
        "bullet": "∙", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "leftrightarrow": "↔", "iff": "⟺", "implies": "⟹", "mapsto": "↦",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "uparrow": "↑", "downarrow": "↓",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬",
        "lnot": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨", "mid": "∣", "parallel": "∥",
        "perp": "⊥", "angle": "∠", "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "prime": "′", "colon": ":", "vert": "|", "Vert": "‖", "|": "‖", "{": "{", "}": "}",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "lbrace": "{", "rbrace": "}", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖",
        "%": "%", "$": "$", "#": "#", "&": "&", "_": "_",
    ]

    /// Large operators; their limits go under and over.
    static let largeOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
    ]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "arg",
        "deg", "dim", "ker", "hom", "Pr", "mod", "bmod",
    ]
    /// Functions whose scripts are limits.
    static let limitFunctions: Set<String> = ["lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "Pr"]

    static let fonts: [String: String] = [
        "mathbf": "bold", "mathit": "italic", "mathrm": "normal", "mathbb": "double-struck", "mathcal": "script",
        "mathscr": "script", "mathfrak": "fraktur", "mathsf": "sans-serif", "mathtt": "monospace",
        "boldsymbol": "bold-italic", "bm": "bold-italic",
    ]

    static let accents: [String: (String, Bool)] = [
        "hat": ("^", false), "widehat": ("^", true), "bar": ("¯", false), "overline": ("¯", true),
        "vec": ("→", false), "overrightarrow": ("→", true), "tilde": ("~", false), "widetilde": ("~", true),
        "dot": ("˙", false), "ddot": ("¨", false), "check": ("ˇ", false), "breve": ("˘", false),
        "acute": ("´", false), "grave": ("`", false),
    ]

    static let spaces: [String: String] = [
        ",": "0.1667em", ":": "0.2222em", ">": "0.2222em", ";": "0.2778em", " ": "0.25em", "quad": "1em",
        "qquad": "2em", "!": "-0.1667em", "enspace": "0.5em", "thinspace": "0.1667em",
    ]

    /// Sizing commands that only change a delimiter's size.
    static let sizers: Set<String> = ["big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
                                      "Biggl", "Biggr", "middle", "displaystyle", "textstyle", "scriptstyle", "limits",
                                      "nolimits", "nonumber", "notag"]

    static let matrices: [String: (String, String)] = [
        "matrix": ("", ""), "smallmatrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"),
        "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", ""),
        "aligned": ("", ""), "align": ("", ""), "align*": ("", ""), "split": ("", ""), "gathered": ("", ""),
        "gather": ("", ""), "gather*": ("", ""), "array": ("", ""), "eqnarray": ("", ""),
    ]

    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Parser

    struct Parser {
        var tokens: [Token]
        var i = 0
        var unsupported: [String] = []

        init(tokens: [Token]) { self.tokens = tokens }

        enum Stop { case close, right, end, align, newline }

        var peek: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func skipSpaces() { while peek == .space { i += 1 } }

        func stops(_ token: Token, _ stop: Set<Stop>) -> Bool {
            switch token {
            case .close: return stop.contains(.close)
            case .align: return stop.contains(.align)
            case .command("right"): return stop.contains(.right)
            case .command("end"): return stop.contains(.end)
            case .command("\\"), .command("cr"): return stop.contains(.newline)
            default: return false
            }
        }

        /// Atoms with their scripts, up to a stop token (not consumed).
        mutating func parseRow(until stop: Set<Stop>) -> String {
            var out = ""
            while true {
                skipSpaces()
                guard let token = peek else { break }
                if stops(token, stop) { break }
                if token == .close { i += 1; continue } // unbalanced: drop
                if token == .align || token == .command("\\") || token == .command("cr") {
                    i += 1
                    if token != .align { out += "<mspace linebreak=\"newline\"/>" }
                    continue
                }
                out += parseScripted()
            }
            return out
        }

        /// One atom and any `^`/`_`/prime that follow it.
        mutating func parseScripted() -> String {
            var (base, limits) = parseAtom()
            var sub: String? = nil, sup: String? = nil
            while true {
                let save = i
                skipSpaces()
                guard let token = peek else { i = save; break }
                if token == .sub, sub == nil {
                    i += 1; sub = parseArgument()
                } else if token == .sup, sup == nil {
                    i += 1; sup = parseArgument()
                } else if token == .symbol("'") {
                    var primes = ""
                    while peek == .symbol("'") { primes += "′"; i += 1 }
                    sup = (sup ?? "") + "<mo>\(primes)</mo>"
                    if sup != "<mo>\(primes)</mo>" { sup = "<mrow>\(sup!)</mrow>" }
                } else if token == .command("limits") {
                    i += 1; limits = true
                } else if token == .command("nolimits") {
                    i += 1; limits = false
                } else {
                    i = save; break
                }
            }
            if base.isEmpty { base = "<mrow></mrow>" }
            switch (sub, sup) {
            case (nil, nil): return base
            case (let s?, nil): return limits ? "<munder>\(base)\(s)</munder>" : "<msub>\(base)\(s)</msub>"
            case (nil, let p?): return limits ? "<mover>\(base)\(p)</mover>" : "<msup>\(base)\(p)</msup>"
            case (let s?, let p?): return limits ? "<munderover>\(base)\(s)\(p)</munderover>" : "<msubsup>\(base)\(s)\(p)</msubsup>"
            }
        }

        /// A script or command argument: a group or a single token.
        mutating func parseArgument() -> String {
            skipSpaces()
            guard let token = peek else { return "<mrow></mrow>" }
            if token == .open {
                i += 1
                let row = parseRow(until: [.close])
                if peek == .close { i += 1 }
                return "<mrow>\(row)</mrow>"
            }
            if case .number(let n) = token, n.count > 1 {
                // `x^23` takes one digit, as TeX does; the rest stays.
                tokens[i] = .number(String(n.dropFirst()))
                return "<mn>\(n.first!)</mn>"
            }
            return parseAtom().0
        }

        /// The raw text of a group argument (for `\text`, `\begin`).
        mutating func parseRawGroup() -> String {
            skipSpaces()
            guard peek == .open else {
                if let token = peek { i += 1; return Self.text(of: token) }
                return ""
            }
            i += 1
            var depth = 1
            var out = ""
            while let token = peek {
                i += 1
                if token == .open { depth += 1 }
                if token == .close { depth -= 1; if depth == 0 { break } }
                out += Self.text(of: token)
            }
            return out
        }

        static func text(of token: Token) -> String {
            switch token {
            case .command(let name): return name.count == 1 && !name.first!.isLetter ? name : "\\" + name
            case .letter(let c), .symbol(let c): return String(c)
            case .number(let n): return n
            case .open: return "{"
            case .close: return "}"
            case .sup: return "^"
            case .sub: return "_"
            case .align: return "&"
            case .space: return " "
            }
        }

        /// One atom; the flag says whether its scripts are limits.
        mutating func parseAtom() -> (String, Bool) {
            skipSpaces()
            guard let token = peek else { return ("", false) }
            i += 1
            switch token {
            case .open:
                let row = parseRow(until: [.close])
                if peek == .close { i += 1 }
                return ("<mrow>\(row)</mrow>", false)
            case .close, .align, .space: return ("", false)
            case .sup, .sub: return ("<mrow></mrow>", false)
            case .number(let n): return ("<mn>\(n)</mn>", false)
            case .letter(let c): return ("<mi>\(escape(String(c)))</mi>", false)
            case .symbol(let c): return (Self.symbol(c), false)
            case .command(let name): return command(name)
            }
        }

        static func symbol(_ c: Character) -> String {
            switch c {
            case "-": return "<mo>−</mo>"
            case "*": return "<mo>∗</mo>"
            case "'": return "<mo>′</mo>"
            case "(", ")", "[", "]", "|": return "<mo stretchy=\"false\">\(c)</mo>"
            case ".": return "<mo>.</mo>"
            default: return "<mo>\(escape(String(c)))</mo>"
            }
        }

        mutating func command(_ name: String) -> (String, Bool) {
            if let g = TeXToMathML.greek[name] {
                return (name.first!.isUppercase ? "<mi mathvariant=\"normal\">\(g)</mi>" : "<mi>\(g)</mi>", false)
            }
            if let s = TeXToMathML.identifiers[name] { return ("<mi>\(s)</mi>", false) }
            if let op = TeXToMathML.largeOperators[name] {
                let limits = !name.contains("int")
                return ("<mo largeop=\"true\"\(limits ? " movablelimits=\"true\"" : "")>\(op)</mo>", limits)
            }
            if let op = TeXToMathML.operators[name] { return ("<mo>\(escape(op))</mo>", false) }
            if TeXToMathML.functions.contains(name) {
                return ("<mi>\(name)</mi>", TeXToMathML.limitFunctions.contains(name))
            }
            if let width = TeXToMathML.spaces[name] { return ("<mspace width=\"\(width)\"/>", false) }
            if let variant = TeXToMathML.fonts[name] {
                let arg = parseArgument()
                return (arg.replacingOccurrences(of: "<mi>", with: "<mi mathvariant=\"\(variant)\">")
                    .replacingOccurrences(of: "<mi mathvariant=\"normal\">", with: "<mi mathvariant=\"\(variant)\">"), false)
            }
            if let (mark, stretchy) = TeXToMathML.accents[name] {
                let arg = parseArgument()
                return ("<mover accent=\"true\">\(arg)<mo stretchy=\"\(stretchy)\">\(escape(mark))</mo></mover>", false)
            }
            if TeXToMathML.sizers.contains(name) { return ("", false) }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let a = parseArgument(), b = parseArgument()
                return ("<mfrac>\(a)\(b)</mfrac>", false)
            case "binom", "dbinom", "tbinom":
                let a = parseArgument(), b = parseArgument()
                return ("<mrow><mo>(</mo><mfrac linethickness=\"0\">\(a)\(b)</mfrac><mo>)</mo></mrow>", false)
            case "sqrt":
                skipSpaces()
                if peek == .symbol("[") {
                    i += 1
                    var index = ""
                    while let t = peek, t != .symbol("]") { index += parseScripted() }
                    if peek == .symbol("]") { i += 1 }
                    return ("<mroot>\(parseArgument())<mrow>\(index)</mrow></mroot>", false)
                }
                return ("<msqrt>\(parseArgument())</msqrt>", false)
            case "text", "textrm", "textup", "mbox", "hbox", "textnormal":
                return ("<mtext>\(escape(parseRawGroup()))</mtext>", false)
            case "textbf":
                return ("<mtext mathvariant=\"bold\">\(escape(parseRawGroup()))</mtext>", false)
            case "textit", "emph":
                return ("<mtext mathvariant=\"italic\">\(escape(parseRawGroup()))</mtext>", false)
            case "operatorname":
                return ("<mi>\(escape(parseRawGroup()))</mi>", false)
            case "underline":
                return ("<munder accentunder=\"true\">\(parseArgument())<mo stretchy=\"true\">_</mo></munder>", false)
            case "overbrace":
                return ("<mover>\(parseArgument())<mo stretchy=\"true\">⏞</mo></mover>", true)
            case "underbrace":
                return ("<munder>\(parseArgument())<mo stretchy=\"true\">⏟</mo></munder>", true)
            case "pmod":
                return ("<mrow><mo>(</mo><mi>mod</mi><mspace width=\"0.3333em\"/>\(parseArgument())<mo>)</mo></mrow>", false)
            case "not":
                let (next, _) = parseAtom()
                return (next.replacingOccurrences(of: "</mo>", with: "\u{338}</mo>"), false)
            case "left":
                let open = delimiter()
                let row = parseRow(until: [.right])
                var close = ""
                if peek == .command("right") { i += 1; close = delimiter() }
                return ("<mrow>\(fence(open))\(row)\(fence(close))</mrow>", false)
            case "right":
                _ = delimiter()
                return ("", false)
            case "begin":
                return (environment(parseRawGroup()), false)
            case "end":
                _ = parseRawGroup()
                return ("", false)
            default:
                unsupported.append("\\" + name)
                return ("<merror><mtext>\\\(escape(name))</mtext></merror>", false)
            }
        }

        /// The delimiter after `\left`/`\right` (empty for `.`).
        mutating func delimiter() -> String {
            skipSpaces()
            guard let token = peek else { return "" }
            i += 1
            switch token {
            case .symbol("."): return ""
            case .symbol(let c): return String(c)
            case .command(let name): return TeXToMathML.operators[name] ?? ""
            default: return ""
            }
        }

        func fence(_ d: String) -> String {
            d.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escape(d))</mo>"
        }

        /// `\begin{env} … \end{env}` as an `<mtable>`.
        mutating func environment(_ name: String) -> String {
            if name == "array" { _ = parseRawGroup() } // column spec
            var rows: [[String]] = [[]]
            while let token = peek {
                if token == .command("end") {
                    i += 1
                    _ = parseRawGroup()
                    break
                }
                let cell = parseRow(until: [.align, .newline, .end])
                rows[rows.count - 1].append(cell)
                guard let next = peek else { break }
                if next == .align { i += 1 } else if next == .command("\\") || next == .command("cr") {
                    i += 1
                    rows.append([])
                }
            }
            if rows.count > 1, rows.last!.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
            let aligned = ["aligned", "align", "align*", "split", "eqnarray"].contains(name)
            let columnAlign = name == "cases" ? " columnalign=\"left\"" : aligned ? " columnalign=\"right left\"" : ""
            var table = "<mtable\(columnAlign)>"
            for row in rows {
                table += "<mtr>"
                for cell in row { table += "<mtd><mrow>\(cell)</mrow></mtd>" }
                table += "</mtr>"
            }
            table += "</mtable>"
            let (open, close) = TeXToMathML.matrices[name] ?? ("", "")
            if TeXToMathML.matrices[name] == nil {
                unsupported.append("\\begin{\(name)}")
            }
            if open.isEmpty && close.isEmpty { return table }
            return "<mrow>\(fence(open))\(table)\(fence(close))</mrow>"
        }
    }
}
