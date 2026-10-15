import AppKit
import SwiftUI

/// Syntax colouring for quick edit: one alternation regex per language, scanned left to right, so a
/// comment or string always wins over the keywords inside it. Gruvbox Dark colours.
final class Highlighter {
    enum Token {
        case comment, string, number, keyword, type, function, constant, key, tag, attribute, heading, meta
        case word   // classified by `Language` into keyword, constant, function, type, or nothing

        var color: NSColor {
            switch self {
            case .comment: return NSColor(Theme.faint)
            case .string: return NSColor(Theme.green)
            case .number, .constant: return NSColor(Theme.purple)
            case .keyword: return NSColor(Theme.red)
            case .type, .attribute, .heading: return NSColor(Theme.yellow)
            case .function, .meta: return NSColor(Theme.aqua)
            case .key, .tag: return NSColor(Theme.blue)
            case .word: return NSColor(Theme.fg)
            }
        }
    }

    let language: Language?
    let regex: NSRegularExpression?
    private let tokens: [Token]          // capture group i + 1 → token

    init(path: String) {
        language = Language.for(path: path)
        guard let language else { regex = nil; tokens = []; return }
        let rules = language.rules + [(.number, Language.number), (.word, language.word)]
        tokens = rules.map(\.0)
        regex = try? NSRegularExpression(pattern: rules.map { "(\($0.1))" }.joined(separator: "|"),
                                         options: language.caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Colours `range` of `storage`. Callers outside the text system's own editing pass wrap this in
    /// begin/endEditing; inside `didProcessEditing` the change folds into the current edit.
    func highlight(_ storage: NSTextStorage, in range: NSRange, font: NSFont, bold: NSFont) {
        storage.addAttributes([.foregroundColor: NSColor(Theme.fg), .font: font], range: range)
        guard let regex, let language else { return }
        let ns = storage.string as NSString
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            for i in 0..<tokens.count {
                let r = match.range(at: i + 1)
                guard r.location != NSNotFound else { continue }
                var token = tokens[i]
                if token == .word {
                    guard let classified = language.classify(ns.substring(with: r), followedBy: Self.nextChar(ns, after: r)) else { return }
                    token = classified
                }
                storage.addAttribute(.foregroundColor, value: token.color, range: r)
                if token == .heading { storage.addAttribute(.font, value: bold, range: r) }
                return
            }
        }
    }

    private static func nextChar(_ ns: NSString, after r: NSRange) -> unichar? {
        var i = NSMaxRange(r)
        while i < ns.length {
            let c = ns.character(at: i)
            if c != 32 && c != 9 { return c }
            i += 1
        }
        return nil
    }
}

/// How a language looks: special tokens in priority order, plus word lists.
struct Language {
    var name: String
    var rules: [(Highlighter.Token, String)]
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var word = #"[A-Za-z_][A-Za-z0-9_]*"#
    var caseInsensitive = false
    var capitalizedAreTypes = true

    static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[A-Za-z%]*\b"#

    func classify(_ word: String, followedBy next: unichar?) -> Highlighter.Token? {
        let key = caseInsensitive ? word.lowercased() : word
        if keywords.contains(key) { return .keyword }
        if constants.contains(key) { return .constant }
        if next == 40 { return .function }                                        // "("
        guard capitalizedAreTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return nil }
        let allCaps = word.count > 1 && word == word.uppercased()
        return allCaps ? .constant : .type
    }

    // MARK: Shared pieces

    private static let blockComment = #"/\*[\s\S]*?(?:\*/|\z)"#
    private static let lineComment = #"//[^\n]*"#
    private static let hashComment = #"(?<![^\s])#[^\n]*"#
    private static let dashComment = #"--[^\n]*"#
    private static let double = #""(?:[^"\\\n]|\\.)*"?"#
    private static let single = #"'(?:[^'\\\n]|\\.)*'?"#
    private static let char = #"'(?:\\.|[^'\\\n])'"#
    private static let backtick = #"`(?:[^`\\]|\\.)*`?"#
    private static let tripleDouble = #""""[\s\S]*?(?:"""|\z)"#
    private static let tripleSingle = #"'''[\s\S]*?(?:'''|\z)"#
    private static let decorator = #"@[A-Za-z_][A-Za-z0-9_]*"#

    private static func cLike(_ name: String, keywords: String, constants: String = "true false null",
                              strings: [String] = [double, char], extra: [(Highlighter.Token, String)] = [],
                              word: String = #"[A-Za-z_][A-Za-z0-9_]*"#) -> Language {
        Language(name: name,
                 rules: [(.comment, blockComment), (.comment, lineComment)] + strings.map { (.string, $0) } + extra,
                 keywords: Set(keywords.split(separator: " ").map(String.init)),
                 constants: Set(constants.split(separator: " ").map(String.init)),
                 word: word)
    }

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    // MARK: Languages

    static let swift = cLike("Swift", keywords: "class struct enum protocol extension func var let if else guard return switch case default for in while repeat break continue fallthrough import public private fileprivate internal open static final override init deinit throws rethrows throw try catch do defer async await actor some any is as where typealias associatedtype mutating nonmutating inout weak unowned lazy get set willSet didSet subscript operator convenience required indirect macro consume borrowing consuming",
                             constants: "true false nil self Self super",
                             strings: [tripleDouble, double], extra: [(.meta, decorator), (.meta, #"#[A-Za-z]+"#)])
    static let rust = cLike("Rust", keywords: "fn let mut const static struct enum trait impl pub crate mod use match if else loop while for in return break continue as ref move async await dyn where type unsafe extern union",
                            constants: "true false self Self super Some None Ok Err",
                            strings: [##"r#*"[\s\S]*?"#*"##, double, char], extra: [(.meta, #"#!?\[[^\]\n]*\]"#), (.meta, #"\b[a-z_][a-z0-9_]*!"#)])
    static let go = cLike("Go", keywords: "func package import var const type struct interface map chan go defer select switch case default if else for range return break continue fallthrough goto",
                          constants: "true false nil iota", strings: [double, char, backtick])
    static let javascript = cLike("JavaScript", keywords: "function const let var if else return for while do switch case default break continue new delete typeof instanceof in of class extends super import export from as async await yield try catch finally throw void static get set interface type enum implements private public protected readonly declare namespace abstract keyof satisfies",
                                  constants: "true false null undefined this NaN Infinity",
                                  strings: [double, single, backtick], extra: [(.meta, decorator)],
                                  word: #"[A-Za-z_$][A-Za-z0-9_$]*"#)
    static let cFamily = cLike("C", keywords: "if else for while do switch case default break continue return goto struct union enum typedef static const extern volatile register sizeof inline auto void int char short long float double unsigned signed bool class public private protected virtual override template typename namespace using new delete operator friend explicit constexpr noexcept throw try catch final abstract interface extends implements package import fun val var when object companion data sealed is in out suspend internal lateinit by init this super instanceof synchronized transient native strictfp assert record yield async await",
                               constants: "true false null nullptr NULL nil YES NO",
                               strings: [double, char], extra: [(.meta, #"(?m:^[ \t]*#[ \t]*[a-z]+)"#), (.meta, decorator)])
    static let python = Language(name: "Python",
                                 rules: [(.string, tripleDouble), (.string, tripleSingle), (.comment, hashComment),
                                         (.string, #"[rbfu]{0,2}"(?:[^"\\\n]|\\.)*"?"#), (.string, #"[rbfu]{0,2}'(?:[^'\\\n]|\\.)*'?"#), (.meta, decorator)],
                                 keywords: words("def class if elif else for while in not and or is return import from as with try except finally raise pass break continue lambda yield global nonlocal assert del async await match case"),
                                 constants: words("None True False self cls"))
    static let ruby = Language(name: "Ruby",
                               rules: [(.comment, hashComment), (.string, double), (.string, single), (.constant, #":[A-Za-z_]\w*"#), (.key, #"@{1,2}[A-Za-z_]\w*"#)],
                               keywords: words("def end class module if elsif else unless case when while until for in do return yield begin rescue ensure raise and or not then require require_relative include extend attr_accessor attr_reader attr_writer private public protected lambda proc"),
                               constants: words("nil true false self"))
    static let shell = Language(name: "Shell",
                                rules: [(.comment, hashComment), (.string, double), (.string, single), (.key, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?@*$!-]"#)],
                                keywords: words("if then else elif fi for while until do done case esac function return in export local readonly declare select time"),
                                constants: words("true false"), capitalizedAreTypes: false)
    static let sql = Language(name: "SQL",
                              rules: [(.comment, blockComment), (.comment, dashComment), (.string, single), (.key, double), (.key, #"\[[^\]\n]*\]"#)],
                              keywords: words("select from where and or not insert into values update set delete create table view index drop alter add column primary key foreign references join left right inner outer full cross on as group by order having limit offset distinct union all case when then else end is in exists between like ilike begin commit rollback transaction declare procedure function returns return if while grant revoke default constraint unique check with recursive over partition top asc desc cascade trigger schema database exec execute go use output into merge using matched truncate"),
                              constants: words("null true false"), caseInsensitive: true, capitalizedAreTypes: false)
    static let lua = Language(name: "Lua",
                              rules: [(.comment, #"--\[\[[\s\S]*?(?:\]\]|\z)"#), (.comment, dashComment), (.string, #"\[\[[\s\S]*?(?:\]\]|\z)"#), (.string, double), (.string, single)],
                              keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
                              constants: words("nil true false self"))
    static let php = cLike("PHP", keywords: "function class interface trait extends implements public private protected static final abstract const var if else elseif endif for foreach endforeach while do switch case default break continue return new use namespace try catch finally throw echo print require require_once include include_once as instanceof fn match readonly enum",
                           constants: "true false null TRUE FALSE NULL this self parent",
                           strings: [double, single], extra: [(.key, #"\$[A-Za-z_]\w*"#), (.comment, hashComment)])
    static let markup = Language(name: "Markup",
                                 rules: [(.comment, #"<!--[\s\S]*?(?:-->|\z)"#), (.string, double), (.string, single),
                                         (.tag, #"</?[A-Za-z][\w:.-]*"#), (.attribute, #"\b[A-Za-z_:@][\w:.-]*(?==)"#), (.constant, #"&[#\w]+;"#)],
                                 word: #"(?!)"#)
    static let css = Language(name: "CSS",
                              rules: [(.comment, blockComment), (.comment, lineComment), (.string, double), (.string, single),
                                      (.number, #"#[0-9a-fA-F]{3,8}\b"#), (.keyword, #"@[\w-]+"#), (.key, #"(?<![\w-])--?[A-Za-z][\w-]*(?=\s*:(?!:))"#),
                                      (.type, #"[.#][A-Za-z_-][\w-]*"#)],
                              constants: words("important inherit initial unset none auto"), word: #"[A-Za-z_-][\w-]*"#, capitalizedAreTypes: false)
    static let json = Language(name: "JSON",
                               rules: [(.comment, lineComment), (.key, #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#), (.string, double)],
                               constants: words("true false null"), capitalizedAreTypes: false)
    static let yaml = Language(name: "YAML",
                               rules: [(.comment, hashComment), (.key, #"(?m:^[ \t]*(?:-[ \t]+)?[A-Za-z_"'][\w.\-"' ]*?)(?=[ \t]*:(?:[ \t]|$))"#),
                                       (.string, double), (.string, single), (.meta, #"[&*][\w-]+"#), (.keyword, #"(?m:^---$)"#)],
                               constants: words("true false null yes no on off"), caseInsensitive: true, capitalizedAreTypes: false)
    static let toml = Language(name: "TOML",
                               rules: [(.comment, hashComment), (.type, #"(?m:^[ \t]*\[[^\]\n]*\])"#), (.key, #"(?m:^[ \t]*[A-Za-z_][\w.\-]*)(?=[ \t]*=)"#),
                                       (.string, tripleDouble), (.string, double), (.string, single)],
                               constants: words("true false"), capitalizedAreTypes: false)
    static let markdown = Language(name: "Markdown",
                                   rules: [(.string, #"(?m:^```[\s\S]*?(?:^```|\z))"#), (.heading, #"(?m:^#{1,6}[ \t][^\n]*)"#), (.string, #"`[^`\n]+`"#),
                                           (.comment, #"(?m:^>[^\n]*)"#), (.key, #"!?\[[^\]\n]+\]\([^)\n]+\)"#), (.type, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#),
                                           (.keyword, #"(?m:^[ \t]*(?:[-*+]|\d+\.)(?=[ \t]))"#)],
                                   word: #"(?!)"#)

    static func `for`(path: String) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "dockerfile", ".gitignore", ".dockerignore", ".env", ".zshrc", ".bashrc", ".zprofile", ".profile": return shell
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return swift
        case "rs": return rust
        case "go": return go
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts": return javascript
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "java", "kt", "kts", "cs", "scala", "dart", "groovy", "gradle", "proto": return cFamily
        case "py", "pyi": return python
        case "rb", "rake", "gemspec": return ruby
        case "sh", "bash", "zsh", "fish", "env": return shell
        case "sql", "psql": return sql
        case "lua": return lua
        case "php": return php
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte", "xaml", "csproj": return markup
        case "css", "scss", "sass", "less": return css
        case "json", "jsonc", "json5": return json
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "properties": return toml
        case "md", "markdown", "mdx": return markdown
        default: return nil
        }
    }
}
