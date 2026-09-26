import Foundation
import LipiCore
import Testing
@testable import LipiApp

@Suite("Byte-identical open and save")
struct TextCodecTests {
    static let fixtures: [(String, [UInt8])] = [
        ("lf", Array("# Title\n\nBody\n".utf8)),
        ("bom", [0xEF, 0xBB, 0xBF] + Array("# ಕನ್ನಡ\nline\n".utf8)),
        ("crlf", Array("# Title\r\n\r\n- a\r\n- b\r\n".utf8)),
        ("cr", Array("one\rtwo\rthree\r".utf8)),
        ("mixed", Array("a\r\nb\nc\rd\r\n\n".utf8)),
        ("noFinalNewline", Array("no newline at end".utf8)),
        ("bomCRLFNoFinal", [0xEF, 0xBB, 0xBF] + Array("x\r\ny".utf8)),
        ("nul", Array("a\u{0}b\n".utf8)),
        ("empty", []),
        ("bomOnly", [0xEF, 0xBB, 0xBF]),
    ]

    @Test(arguments: fixtures.map(\.0))
    func roundTripIsByteIdentical(_ name: String) throws {
        let original = Data(Self.fixtures.first { $0.0 == name }!.1)
        let decoded = TextCodec.decode(original)
        #expect(!decoded.isReadOnly)
        #expect(TextCodec.encode(LipiRope(decoded.text), format: decoded.format) == original)
    }

    @Test(arguments: fixtures.map(\.0))
    func roundTripThroughAtomicWriter(_ name: String) throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("\(name).md")
        let original = Data(Self.fixtures.first { $0.0 == name }!.1)
        try original.write(to: url)
        let decoded = TextCodec.decode(try Data(contentsOf: url))
        var options = AtomicWriter.Options()
        options.coordinate = false
        try AtomicWriter(options: options).write(TextCodec.encode(LipiRope(decoded.text), format: decoded.format), to: url)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func detectsFormat() {
        let bom = TextCodec.decode(Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb".utf8)))
        #expect(bom.format.hasBOM)
        #expect(bom.format.lineEnding == .crlf)
        #expect(!bom.format.hasFinalNewline)
        #expect(bom.text == "a\r\nb")
        #expect(TextCodec.decode(bytes("a\rb\r")).format.lineEnding == .cr)
        #expect(TextCodec.decode(bytes("a\rb\n")).format.lineEnding == .mixed)
        #expect(TextCodec.decode(bytes("a\nb\n")).format.lineEnding == .lf)
        #expect(TextCodec.decode(bytes("ab")).format.lineEnding == LineEndingStyle.none)
        #expect(TextCodec.decode(bytes("a\n")).format.hasFinalNewline)
    }

    @Test func editKeepsBytesOutsideTheEdit() {
        let original = Array("a\r\nb\nc\r".utf8)
        let decoded = TextCodec.decode(Data(original))
        var buffer = SourceBuffer(decoded.text)
        _ = buffer.apply(Edit(range: SourceOffset(3)..<SourceOffset(4), replacement: "B"))  // the "b" on the LF line
        let saved = TextCodec.encode(buffer.rope, format: decoded.format)
        #expect(saved == bytes("a\r\nB\nc\r"))
    }

    @Test func nonUTF8OpensReadOnlyAndSavesOriginalBytes() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])  // "café\n" in Latin-1
        let decoded = TextCodec.decode(latin1)
        #expect(decoded.isReadOnly)
        #expect(!decoded.format.isUTF8)
        #expect(decoded.originalBytes == latin1)
        #expect(decoded.text.hasPrefix("caf"))

        let utf16 = "hello\n".data(using: .utf16)!
        let decoded16 = TextCodec.decode(utf16)
        #expect(decoded16.isReadOnly)
        #expect(decoded16.text == "hello\n")
    }
}
