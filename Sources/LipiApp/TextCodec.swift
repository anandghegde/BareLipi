import Foundation
import LipiCore

/// Line-ending style detected on open (PRD §6.1.7). Informational: the rope
/// keeps every line's own ending, so nothing is converted on save.
public enum LineEndingStyle: String, Sendable, Codable, Equatable {
    /// No line breaks at all.
    case none
    case lf
    case crlf
    case cr
    /// More than one style; each line keeps its own.
    case mixed

    /// Classifies the line breaks in `bytes`.
    public static func detect<C: Collection>(in bytes: C) -> LineEndingStyle where C.Element == UInt8 {
        var lf = 0, crlf = 0, cr = 0
        var previousCR = false
        for byte in bytes {
            if byte == 0x0A {
                if previousCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousCR = false
            } else if byte == 0x0D {
                cr += 1
                previousCR = true
            } else {
                previousCR = false
            }
        }
        switch (lf > 0, crlf > 0, cr > 0) {
        case (false, false, false): return .none
        case (true, false, false): return .lf
        case (false, true, false): return .crlf
        case (false, false, true): return .cr
        default: return .mixed
        }
    }
}

/// How a document's bytes were encoded on disk, recorded on open so a save
/// re-emits exactly what was read (PRD §6.1.7, ADR-008).
public struct TextFormat: Sendable, Equatable {
    /// The file started with the UTF-8 byte order mark `EF BB BF`. The BOM is
    /// kept out of the rope and written back in front of it.
    public var hasBOM: Bool
    public var lineEnding: LineEndingStyle
    /// The last byte is `\n` or `\r`.
    public var hasFinalNewline: Bool
    /// The encoding the text was decoded with. Anything but `.utf8` means
    /// the document is read-only until converted.
    public var encoding: String.Encoding

    public init(hasBOM: Bool = false, lineEnding: LineEndingStyle = .none, hasFinalNewline: Bool = false, encoding: String.Encoding = .utf8) {
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.hasFinalNewline = hasFinalNewline
        self.encoding = encoding
    }

    public var isUTF8: Bool { encoding == .utf8 }

    /// A human name for the encoding, for the banner and the status bar.
    public var encodingName: String {
        String.localizedName(of: encoding)
    }
}

/// The result of decoding a file's bytes.
public struct DecodedText: Sendable {
    /// The text the editor shows (without a UTF-8 BOM).
    public var text: String
    public var format: TextFormat
    /// For a file that is not valid UTF-8: the bytes exactly as read. While
    /// the document is unconverted these are what a save writes back, so an
    /// accidental save never changes the file.
    public var originalBytes: Data?
    /// Decoding had to substitute characters (only for non-UTF-8 input).
    public var usedLossyConversion: Bool

    /// Non-UTF-8 files open read-only with a conversion banner (§6.1.7).
    public var isReadOnly: Bool { originalBytes != nil }
}

/// Byte-exact decoding and encoding of document files (PRD §6.1.7). UTF-8
/// input round-trips byte-identically: the BOM is remembered and re-emitted,
/// and line endings, NUL bytes and the final newline live in the rope as
/// they were read.
public enum TextCodec {
    public static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decodes a file's bytes. Valid UTF-8 (with or without a BOM) decodes
    /// losslessly; anything else is detected with
    /// `NSString.stringEncoding(for:…)` and returned with `originalBytes` set.
    public static func decode(_ data: Data) -> DecodedText {
        let hasBOM = data.starts(with: utf8BOM)
        let body = hasBOM ? data.dropFirst(utf8BOM.count) : data[...]
        let ending = LineEndingStyle.detect(in: body)
        let finalNewline = body.last == 0x0A || body.last == 0x0D
        if let text = String(validating: body, as: UTF8.self) {
            return DecodedText(
                text: text,
                format: TextFormat(hasBOM: hasBOM, lineEnding: ending, hasFinalNewline: finalNewline, encoding: .utf8),
                originalBytes: nil, usedLossyConversion: false)
        }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.utf16.rawValue, String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue]],
                                          convertedString: &converted, usedLossyConversion: &lossy)
        let encoding = raw == 0 ? String.Encoding.isoLatin1 : String.Encoding(rawValue: raw)
        let text = (converted as String?) ?? String(decoding: data, as: UTF8.self)
        let textBytes = Array(text.utf8)
        return DecodedText(
            text: text,
            format: TextFormat(hasBOM: false, lineEnding: LineEndingStyle.detect(in: textBytes),
                               hasFinalNewline: textBytes.last == 0x0A || textBytes.last == 0x0D, encoding: encoding),
            originalBytes: data, usedLossyConversion: raw == 0 || lossy.boolValue)
    }

    /// The bytes to write for `rope` in `format`: the BOM when the file had
    /// one, then the rope's UTF-8 exactly. No normalisation of any kind.
    public static func encode(_ rope: LipiRope, format: TextFormat) -> Data {
        var data = Data()
        data.reserveCapacity(rope.count + (format.hasBOM ? 3 : 0))
        if format.hasBOM { data.append(contentsOf: utf8BOM) }
        rope.forEachChunk { chunk in
            var chunk = chunk
            chunk.withUTF8 { buffer in
                if let base = buffer.baseAddress, buffer.count > 0 { data.append(base, count: buffer.count) }
            }
        }
        return data
    }
}
