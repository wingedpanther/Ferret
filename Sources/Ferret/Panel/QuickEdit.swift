import AppKit
import SwiftUI

/// A file open for quick editing in the panel: what was loaded, what's changed, and saving it back.
@MainActor
final class EditSession: ObservableObject {
    static let maxBytes = 1_000_000

    let path: String
    let readOnly: Bool
    /// Where to put the cursor on open: the match's range in UTF-16 units, or a whole line.
    let initialLine: Int
    let initialMatch: (column: Int, length: Int)?

    @Published private(set) var isDirty = false
    @Published var message: String?                      // a save result or a warning, in the footer
    @Published var cursor = (line: 1, column: 1)
    /// Soft wrap, toggled with ⌥Z and remembered across files.
    @Published var wrap = UserDefaults.standard.object(forKey: "quickEditWrap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wrap, forKey: "quickEditWrap") }
    }

    private(set) var savedText: String
    private(set) var text: String
    private var loadedModified: Date?
    private var discardArmed = false                     // Esc pressed once with unsaved changes
    private var overwriteArmed = false                   // ⌘S pressed once after the file changed on disk

    var name: String { (path as NSString).lastPathComponent }

    enum OpenError: LocalizedError {
        case folder, tooBig(Int), binary, unreadable

        var errorDescription: String? {
            switch self {
            case .folder: return "Folders can't be edited — ↩ to open, ⌘T for a terminal."
            case .tooBig(let n): return "Too big to quick-edit (\(Format.size(UInt64(n)))). ⌥↩ opens it in your editor."
            case .binary: return "Not a text file. ⌘Y previews it."
            case .unreadable: return "Couldn't read this file as UTF-8 text."
            }
        }
    }

    init(path: String, line: Int = 1, match: (column: Int, length: Int)? = nil) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { throw OpenError.folder }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxBytes else { throw OpenError.tooBig(size) }
        guard let data = FileManager.default.contents(atPath: path) else { throw OpenError.unreadable }
        guard !data.prefix(8192).contains(0) else { throw OpenError.binary }
        guard let text = String(data: data, encoding: .utf8) else { throw OpenError.unreadable }

        self.path = path
        self.text = text
        savedText = text
        loadedModified = attrs?[.modificationDate] as? Date
        readOnly = !FileManager.default.isWritableFile(atPath: path)
        initialLine = max(1, line)
        initialMatch = match
        if readOnly { message = "Read-only. You can't save this file." }
    }

    func textChanged(_ new: String) {
        text = new
        isDirty = text != savedText
        discardArmed = false
        if isDirty, message?.hasPrefix("Saved") == true { message = nil }
    }

    /// Writes through a temporary file and `replaceItemAt`, which keeps the file's permissions and
    /// extended attributes. Asks for a second ⌘S if the file changed on disk since it was opened.
    func save() -> Bool {
        guard !readOnly else { message = "This file is read-only."; return false }
        guard isDirty else { message = "No changes to save."; return true }
        let url = URL(fileURLWithPath: path)
        let current = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let current, let loadedModified, current > loadedModified, !overwriteArmed {
            overwriteArmed = true
            message = "Changed on disk since you opened it — ⌘S again to overwrite."
            return false
        }
        do {
            let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: url, create: true)
            let temp = scratch.appendingPathComponent(name)
            try Data(text.utf8).write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            try? FileManager.default.removeItem(at: scratch)
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
            return false
        }
        savedText = text
        isDirty = false
        overwriteArmed = false
        loadedModified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        message = "Saved \(Date().formatted(date: .omitted, time: .shortened))"
        return true
    }

    /// True when it's fine to close. With unsaved changes, the first call warns and the second agrees.
    func confirmClose() -> Bool {
        guard isDirty, !readOnly else { return true }
        if discardArmed { return true }
        discardArmed = true
        message = "Unsaved changes — ⌘S to save, Esc again to discard."
        return false
    }
}

// MARK: - View

struct QuickEditView: View {
    @ObservedObject var session: EditSession
    let focusToken: Int

    var body: some View {
        CodeEditor(session: session, focusToken: focusToken)
            .background(Theme.bg)
    }
}

/// The header while editing: which file, where, and whether it has unsaved changes.
struct EditHeader: View {
    @ObservedObject var session: EditSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.readOnly ? "lock" : "pencil").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(session.name).font(Theme.font(16, .semibold)).foregroundStyle(Theme.fg)
            if session.isDirty { Circle().fill(Theme.yellow).frame(width: 7, height: 7).help("Unsaved changes") }
            Text(Format.path((session.path as NSString).deletingLastPathComponent))
                .font(Theme.font(12)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.head)
            Spacer()
        }
    }
}

struct EditFooterStatus: View {
    @ObservedObject var session: EditSession

    var body: some View {
        if let message = session.message {
            Text(message).font(Theme.font(11)).foregroundStyle(message.hasPrefix("Saved") ? Theme.green : Theme.yellow)
        } else {
            Text("Ln \(session.cursor.line), Col \(session.cursor.column)").font(Theme.font(11)).foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Text view

/// A code editor: JetBrains Mono, Gruvbox syntax colouring, line numbers, optional soft wrap, undo,
/// find, auto-indent and the file's own indent unit for Tab.
struct CodeEditor: NSViewRepresentable {
    let session: EditSession
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isEditable = !session.readOnly
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)

        let font = NSFont(name: Theme.family, size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor(Theme.fg)]
        let bold = NSFont(descriptor: font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold]]),
                          size: font.pointSize) ?? font
        textView.backgroundColor = NSColor(Theme.bg)
        textView.insertionPointColor = NSColor(Theme.fg)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Color(hex: 0x665C54))]
        textView.string = session.text
        let coordinator = context.coordinator
        coordinator.font = font
        coordinator.bold = bold
        coordinator.highlighter = Highlighter(path: session.path)
        coordinator.highlightAll(storage)
        storage.delegate = coordinator
        textView.delegate = coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.bg)
        scroll.scrollerStyle = .overlay

        let ruler = LineNumberRuler(textView: textView, font: font)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.ruler = ruler
        context.coordinator.indentUnit = Coordinator.detectIndent(session.text)
        // Wrapping needs the scroll view's real width, which it has only after the first layout.
        DispatchQueue.main.async {
            context.coordinator.setWrap(session.wrap)
            context.coordinator.placeCursor()
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let wrapping = context.coordinator.wrapping, wrapping != session.wrap { context.coordinator.setWrap(session.wrap) }
        // The panel bumps the token when it reappears; take focus back from the search field.
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                if let tv = context.coordinator.textView { tv.window?.makeFirstResponder(tv) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let session: EditSession
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var ruler: LineNumberRuler?
        var indentUnit = "    "
        var focusToken = 0
        var highlighter: Highlighter?
        var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        var bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
        private(set) var wrapping: Bool?
        private var fullPass: DispatchWorkItem?

        /// Files bigger than this only get their edited lines recoloured while typing.
        static let fullPassLimit = 300_000

        func highlightAll(_ storage: NSTextStorage) {
            storage.beginEditing()
            highlighter?.highlight(storage, in: NSRange(location: 0, length: storage.length), font: font, bold: bold)
            storage.endEditing()
        }

        /// Recolours the edited lines at once, then the whole file shortly after typing stops,
        /// which fixes comments and strings that span lines.
        nonisolated func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                                     range edited: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                let lines = (storage.string as NSString).lineRange(for: edited)
                highlighter?.highlight(storage, in: lines, font: font, bold: bold)
                guard storage.length <= Self.fullPassLimit else { return }
                fullPass?.cancel()
                let work = DispatchWorkItem { [weak self, weak storage] in
                    guard let self, let storage else { return }
                    MainActor.assumeIsolated { self.highlightAll(storage) }
                }
                fullPass = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }

        /// Soft wrap fits lines to the view; without it, lines run on and the view scrolls sideways.
        func setWrap(_ on: Bool) {
            guard let tv = textView, let scroll = scrollView, let container = tv.textContainer else { return }
            wrapping = on
            let big = CGFloat.greatestFiniteMagnitude
            // Less the ruler, which the clip view leaves room for with a left inset.
            let visible = NSSize(width: scroll.contentSize.width - scroll.contentView.contentInsets.left, height: scroll.contentSize.height)
            scroll.hasHorizontalScroller = !on
            tv.minSize = NSSize(width: 0, height: visible.height)
            if on {
                tv.isHorizontallyResizable = false
                container.widthTracksTextView = true
                // Setting the frame makes the container follow the view's width.
                tv.setFrameSize(NSSize(width: visible.width, height: max(tv.frame.height, visible.height)))
            } else {
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: big, height: big)
                tv.isHorizontallyResizable = true
            }
            tv.layoutManager?.ensureLayout(for: container)
            tv.sizeToFit()
            tv.setFrameOrigin(.zero)
            ruler?.invalidateLines()
        }

        init(session: EditSession) { self.session = session }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            session.textChanged(tv.string)
            ruler?.invalidateLines()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let location = min(tv.selectedRange().location, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            session.cursor = ((ruler?.lineIndex(at: location, in: ns) ?? 0) + 1, location - lineRange.location + 1)
            ruler?.needsDisplay = true
        }

        /// Tab inserts the file's indent unit; Return keeps the current line's indentation.
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                tv.insertText(indentUnit, replacementRange: tv.selectedRange())
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let ns = tv.string as NSString
                let line = ns.substring(with: ns.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0)))
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                tv.insertText("\n" + indent, replacementRange: tv.selectedRange())
                return true
            default:
                return false
            }
        }

        /// Selects the match (or the line start) and scrolls it to the middle of the view.
        func placeCursor() {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            var start = 0, line = 1
            while line < session.initialLine, start < ns.length {
                start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                line += 1
            }
            var range = NSRange(location: min(start, ns.length), length: 0)
            if let m = session.initialMatch {
                let lineEnd = NSMaxRange(ns.lineRange(for: range))
                let location = min(start + m.column, lineEnd)
                range = NSRange(location: location, length: min(m.length, max(0, lineEnd - location)))
            }
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
            if let clip = tv.enclosingScrollView?.contentView, let rect = tv.layoutManager.map({
                $0.boundingRect(forGlyphRange: $0.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tv.textContainer!)
            }) {
                let y = max(0, rect.midY - clip.bounds.height / 2)
                // The clip view insets itself past the line-number ruler; x 0 would put text under it.
                clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: y))
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        /// Tab for tab-indented files, else the smallest common space indent (2 or 4), defaulting to 4.
        static func detectIndent(_ text: String) -> String {
            var tabs = 0, widths: [Int: Int] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
                if line.hasPrefix("\t") { tabs += 1; continue }
                let n = line.prefix { $0 == " " }.count
                if n > 0, n <= 8, line.count > n { widths[n, default: 0] += 1 }
            }
            if tabs > widths.values.reduce(0, +) { return "\t" }
            if (widths[2] ?? 0) > 0 && (widths[2] ?? 0) >= (widths[4] ?? 0) / 2 && widths.keys.min() == 2 { return "  " }
            return "    "
        }
    }
}

/// Line numbers down the left edge, drawn only for visible lines.
final class LineNumberRuler: NSRulerView {
    private let font: NSFont
    private var lineStarts: [Int] = [0]
    private var stale = true

    init(textView: NSTextView, font: NSFont) {
        self.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize - 1.5) ?? font
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func invalidateLines() {
        stale = true
        needsDisplay = true
    }

    /// 0-based line containing `location`, by binary search over cached line starts.
    func lineIndex(at location: Int, in ns: NSString) -> Int {
        if stale { recount(ns) }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func recount(_ ns: NSString) {
        lineStarts = [0]
        var i = 0
        while i < ns.length {
            let r = ns.lineRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(r)
            if i < ns.length || (i == ns.length && ns.length > 0 && ns.character(at: ns.length - 1) == 10) { lineStarts.append(i) }
        }
        stale = false
        let digits = max(3, String(lineStarts.count).count)
        ruleThickness = CGFloat(digits) * 8 + 16
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(Theme.bg).setFill()
        bounds.fill()
        guard let tv = clientView as? NSTextView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
        let ns = tv.string as NSString
        if stale { recount(ns) }

        let visible = tv.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let current = lineIndex(at: min(tv.selectedRange().location, ns.length), in: ns)
        let inset = tv.textContainerInset.height
        var index = lineIndex(at: chars.location, in: ns)
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(chars) {
            let start = lineStarts[index]
            let glyph = start < ns.length ? layout.glyphIndexForCharacter(at: start) : max(0, layout.numberOfGlyphs - 1)
            var lineRect = layout.numberOfGlyphs == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if start >= ns.length, layout.numberOfGlyphs > 0 { lineRect = layout.extraLineFragmentRect }
            let y = lineRect.minY + inset - visible.minY
            let label = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(index == current ? Theme.accent : Theme.faint.opacity(0.7)),
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2), withAttributes: attrs)
            index += 1
        }
    }
}
