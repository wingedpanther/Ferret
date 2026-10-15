import AppKit

/// Development aid: `FERRET_SNAPSHOT=<dir> Ferret` renders the panel in each scenario to PNGs, then quits.
/// It renders the view itself, so it needs no Screen Recording permission.
@MainActor
enum Snapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["FERRET_SNAPSHOT"] }

    static func run(panel: LauncherPanel, model: LauncherModel) {
        guard let dir = directory else { return }
        let scenarios: [(String, Mode, String)] = [
            ("files", .files, "mian.rs"),
            ("files-empty", .files, ""),
            ("grep", .grep, "fn install"),
            ("symbols", .symbols, "LauncherModel"),
            ("git", .git, ""),
            ("recent", .recent, ""),
        ]
        Task {
            try? await Task.sleep(for: .seconds(2))           // status, repos and their counts
            for (name, mode, query) in scenarios {
                model.mode = mode
                model.query = query
                model.refresh()
                try? await Task.sleep(for: .milliseconds(mode == .git ? 2500 : 900))
                model.move(1)
                try? await Task.sleep(for: .milliseconds(400)) // thumbnails
                write(panel, to: "\(dir)/\(name).png")
            }
            // Inside the first repo with changes.
            model.mode = .git
            try? await Task.sleep(for: .milliseconds(500))
            if let i = model.items.firstIndex(where: { if case .repo(let r) = $0 { return (r.changed ?? 0) > 0 }; return false }) {
                model.selection = i
                _ = model.primary()
                try? await Task.sleep(for: .seconds(2))
                write(panel, to: "\(dir)/git-changes.png")
            }
            // Quick edit on a grep match.
            _ = model.leaveRepo()
            model.mode = .grep
            model.query = "func startEdit"
            model.refresh()
            try? await Task.sleep(for: .milliseconds(900))
            model.startEdit()
            try? await Task.sleep(for: .milliseconds(600))
            write(panel, to: "\(dir)/quick-edit.png")
            _ = model.endEdit(force: true)
            // The search field gets focus back with the query kept and the cursor at the end.
            try? await Task.sleep(for: .milliseconds(300))
            var log = "after quick edit: " + focusState(panel) + "\n"
            panel.makeFirstResponder(nil)
            log += "focus lost: " + focusState(panel) + "\n"
            panel.focusSearchField()
            log += "after ⌘L: " + focusState(panel) + "\n"
            try? log.write(toFile: "\(dir)/focus.txt", atomically: true, encoding: .utf8)
            AppDelegate.shared?.showSettings()
            try? await Task.sleep(for: .milliseconds(800))
            if let settings = NSApp.windows.first(where: { $0.title == "Ferret Settings" }) {
                write(settings, to: "\(dir)/settings.png")
            }
            NSApp.terminate(nil)
        }
    }

    private static func focusState(_ panel: NSWindow) -> String {
        guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else { return "search field not focused" }
        return "\"\(editor.string)\" selection \(editor.selectedRange())"
    }

    private static func write(_ panel: NSWindow, to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
