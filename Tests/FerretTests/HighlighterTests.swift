import AppKit
import Testing
@testable import Ferret

@MainActor
struct HighlighterTests {
    static let samples = ["a.swift", "a.rs", "a.go", "a.ts", "a.c", "a.kt", "a.py", "a.rb", "a.sh", "Makefile", "a.sql",
                          "a.lua", "a.php", "a.html", "a.css", "a.json", "a.yaml", "a.toml", "a.md"]

    @Test(arguments: samples) func everyLanguageCompiles(_ path: String) {
        let h = Highlighter(path: path)
        #expect(h.language != nil)
        #expect(h.regex != nil, "pattern for \(path) doesn't compile")
    }

    @Test func plainFilesStayUncoloured() {
        #expect(Highlighter(path: "notes.txt").language == nil)
    }

    private func colours(_ text: String, path: String) -> (String) -> NSColor? {
        let storage = NSTextStorage(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        Highlighter(path: path).highlight(storage, in: NSRange(location: 0, length: storage.length), font: font, bold: font)
        return { needle in
            let r = (text as NSString).range(of: needle)
            return r.location == NSNotFound ? nil : storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
        }
    }

    @Test func stringsAndCommentsWinOverKeywords() {
        let at = colours("let s = \"if // no\" // return here\nfunc foo() { Bar.baz(42) }", path: "x.swift")
        #expect(at("let") == Highlighter.Token.keyword.color)
        #expect(at("\"if") == Highlighter.Token.string.color)
        #expect(at("// return") == Highlighter.Token.comment.color)
        #expect(at("foo") == Highlighter.Token.function.color)
        #expect(at("Bar") == Highlighter.Token.type.color)
        #expect(at("42") == Highlighter.Token.number.color)
    }

    @Test func jsonKeysDifferFromValues() {
        let at = colours(#"{"name": "fsearch", "ok": true}"#, path: "x.json")
        #expect(at(#""name""#) == Highlighter.Token.key.color)
        #expect(at(#""fsearch""#) == Highlighter.Token.string.color)
        #expect(at("true") == Highlighter.Token.constant.color)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let at = colours("SELECT id FROM users -- all\nwhere x = 'a'", path: "q.sql")
        #expect(at("SELECT") == Highlighter.Token.keyword.color)
        #expect(at("where") == Highlighter.Token.keyword.color)
        #expect(at("-- all") == Highlighter.Token.comment.color)
        #expect(at("'a'") == Highlighter.Token.string.color)
    }
}
