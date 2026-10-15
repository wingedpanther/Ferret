import AppKit
import Combine
import Quartz
import SwiftUI

/// A floating, borderless panel that takes keys without activating the app, like Spotlight.
final class LauncherPanel: NSPanel, QLPreviewPanelDataSource {
    private let model: LauncherModel
    private var keyMonitor: Any?
    private var focusWatch: AnyCancellable?

    init(model: LauncherModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: LauncherView(model: model) { [weak self] close in
            if close { self?.dismiss(reset: true) }
        })
        host.sizingOptions = []
        contentView = host
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handle(event) ? nil : event
        }
        // The model bumps focusToken when it wants the search field back (showing, leaving quick edit).
        focusWatch = model.$focusToken.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.focusSearchField() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        isVisible && isKeyWindow ? dismiss(reset: false) : present()
    }

    func present() {
        // Upper third of the screen with the mouse, as Spotlight does.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + f.height * 0.68 - frame.height / 2))
        }
        model.willShow()
        makeKeyAndOrderFront(nil)
    }

    func dismiss(reset: Bool) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        orderOut(nil)
        if reset { model.reset() }
    }

    override func resignKey() {
        super.resignKey()
        // Quick Look takes key while it's up; anything else means the user went elsewhere.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        dismiss(reset: false)
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if model.editSession != nil { return handleEditing(event, mods: mods, chars: chars) }

        switch Int(event.keyCode) {
        case 125: model.move(1); return true                                  // ↓
        case 126: model.move(-1); return true                                 // ↑
        case 121: model.move(8); return true                                  // page down
        case 116: model.move(-8); return true                                 // page up
        case 48: model.cycleMode(mods.contains(.shift) ? -1 : 1); return true // tab
        case 53:                                                              // esc
            if model.leaveRepo() { return true }
            if !model.query.isEmpty { model.query = ""; return true }
            dismiss(reset: false)
            return true
        case 123 where model.query.isEmpty:                                   // ← leaves a repo
            return model.leaveRepo()
        case 36, 76:                                                          // ↩
            let close: Bool
            if mods == .command { close = model.reveal() }
            else if mods == .option { close = model.openInEditor() }
            else { close = model.primary() }
            if close { dismiss(reset: true) }
            return true
        default: break
        }

        // Typing while focus is elsewhere (after a click, say) goes to the search field.
        if !searchFieldHasFocus, mods.isDisjoint(with: [.command, .control]),
           let typed = event.characters, typed.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) || event.keyCode == 51 {
            focusSearchField()
            return false
        }

        if mods == .control, chars == "n" { model.move(1); return true }
        if mods == .control, chars == "p" { model.move(-1); return true }
        guard mods == .command else { return false }
        switch chars {
        case "1", "2", "3", "4", "5":
            model.mode = Mode(rawValue: Int(chars)! - 1)!
            return true
        case "l", "f":
            focusSearchField()
            return true
        case "t":
            if model.openTerminal() { dismiss(reset: true) }
            return true
        case "e":
            model.startEdit()
            return true
        case "y":
            toggleQuickLook()
            return true
        case "c":
            // Copy the path unless text is selected in the search field.
            if let editor = firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            model.copyPath()
            return true
        case "v", "x", "a", "z":
            let action: Selector = ["v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
                                    "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:"))][chars]!
            return NSApp.sendAction(action, to: nil, from: self)
        case ",":
            AppDelegate.shared?.showSettings()
            return true
        default:
            return false
        }
    }

    /// Puts the cursor at the end of the search field, keeping what's typed there.
    func focusSearchField() {
        guard model.editSession == nil, let field = searchField else { return }
        if !searchFieldHasFocus { makeFirstResponder(field) }
        let end = (field.stringValue as NSString).length
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: end, length: 0))
    }

    private var searchField: NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, !(field is NSSearchField) { return field }
            for sub in view.subviews { if let field = find(sub) { return field } }
            return nil
        }
        return contentView.flatMap(find)
    }

    private var searchFieldHasFocus: Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate as? NSTextField === searchField
    }

    /// While quick-editing, the text view gets every key except these.
    private func handleEditing(_ event: NSEvent, mods: NSEvent.ModifierFlags, chars: String) -> Bool {
        // The find bar's field is a field editor; let it have its own Esc and Return.
        let inFindBar = (firstResponder as? NSTextView)?.isFieldEditor == true
        let close = Int(event.keyCode) == 53 || (mods == .command && chars == "w")
        if close {
            if inFindBar, Int(event.keyCode) == 53 { return false }
            _ = model.endEdit()
            return true
        }
        if mods == .option, Int(event.keyCode) == 6 {                     // ⌥Z
            model.editSession?.wrap.toggle()
            return true
        }
        if mods == .option, [36, 76].contains(Int(event.keyCode)) {
            if model.openEditSessionInEditor() { dismiss(reset: true) }
            return true
        }
        guard mods == .command || mods == [.command, .shift] else { return false }
        switch (chars, mods == .command) {
        case ("s", true):
            _ = model.editSession?.save()
            return true
        case ("f", true), ("g", true), ("g", false):
            guard !inFindBar || chars == "g" else { return true }
            let action: NSTextFinder.Action = chars == "f" ? .showFindInterface : mods == .command ? .nextMatch : .previousMatch
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            return NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: editorTextView, from: sender)
        case ("z", false):
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        case ("c", true), ("v", true), ("x", true), ("a", true), ("z", true):
            let action: Selector = ["c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
                                    "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:"))][chars]!
            return NSApp.sendAction(action, to: nil, from: self)
        default:
            return mods == .command && chars == "e"   // already editing
        }
    }

    /// The quick-edit text view (not the find bar's field editor).
    private var editorTextView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, !tv.isFieldEditor, tv.enclosingScrollView?.verticalRulerView != nil { return tv }
            for sub in view.subviews { if let tv = find(sub) { return tv } }
            return nil
        }
        return contentView.flatMap(find)
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard model.selected != nil else { return }
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.selected == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        URL(fileURLWithPath: model.selected?.path ?? "/") as NSURL
    }
}
