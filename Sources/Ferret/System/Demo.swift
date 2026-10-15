import AppKit
import FSearchKit

/// Development aid: `FERRET_DEMO=<dir> FERRET_SCOPE=~/ferret-demo Ferret` plays the demo script on the
/// real panel and writes a frame at every change, plus manifest.json with how long each frame shows.
/// scripts/demo/record.sh turns that into the video. Run scripts/demo/make-repos.sh first.
@MainActor
final class Demo {
    static var directory: String? { ProcessInfo.processInfo.environment["FERRET_DEMO"] }

    private let dir: String
    private let panel: LauncherPanel
    private let model: LauncherModel
    private var frames: [[String: Any]] = []
    private var caption = ""

    private init(dir: String, panel: LauncherPanel, model: LauncherModel) {
        self.dir = dir
        self.panel = panel
        self.model = model
    }

    static func run(panel: LauncherPanel, model: LauncherModel) {
        guard let dir = directory else { return }
        guard FSearchClient.scope != nil else {
            print("FERRET_DEMO needs FERRET_SCOPE, so nothing outside the demo folder can show up")
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let demo = Demo(dir: dir, panel: panel, model: model)
        Task { await demo.play() }
    }

    // MARK: Script

    private func play() async {
        await wait(2500)                                       // repos and their git counts

        caption = "Find any file. Typos are fine."
        model.mode = .files
        await shot(900, key: "⌥Space")
        await type("wroker")
        await shot(1400)

        caption = "Preview as you move. ⌘Y opens Quick Look."
        model.query = ""
        await type("readme")
        await shot(700, settle: 300)
        for _ in 0..<2 { model.move(1); await shot(750, key: "↓", settle: 350) }
        model.query = ""
        await type("poster")
        model.selection = 0
        await shot(1600, settle: 500)

        caption = "Search inside every file in every repo."
        model.query = ""
        await type("/")
        await shot(500, key: "/")
        await type("backoff")
        await shot(1600)
        model.move(1)
        await shot(900, key: "↓", settle: 250)

        caption = "Jump to a definition, in any language."
        model.query = ""
        await type("#")
        await shot(400, key: "#")
        await type("Config")
        await shot(1800)

        caption = "Every repo with uncommitted changes."
        model.query = ""
        await type("!")
        await wait(400)
        await shot(1700, key: "!")
        if let i = model.items.firstIndex(where: { if case .repo(let r) = $0 { return r.name == "tidepool" }; return false }) {
            model.selection = i
            await shot(600, settle: 200)
            _ = model.primary()
            await shot(1700, key: "↩", settle: 900)
        }

        caption = "Edit right here with ⌘E."
        _ = model.leaveRepo()
        model.mode = .grep
        model.query = ""
        await type("maxBackoff")
        await wait(400)
        if let i = model.items.firstIndex(where: { if case .match(_, _, let m) = $0 { return m.text.contains("maxBackoff  =") }; return false }) {
            model.selection = i
        }
        await shot(1000, settle: 250)
        model.startEdit()
        await shot(1300, key: "⌘E", settle: 600)
        await editRetryCap()

        caption = "⌘S saves it to disk."
        _ = model.editSession?.save()
        await shot(1500, key: "⌘S", settle: 200)

        caption = "Open it in ttt, on the same line."
        await shot(1600, key: "⌥↩")

        try? JSONSerialization.data(withJSONObject: ["frames": frames, "scope": FSearchClient.scope ?? ""], options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: "\(dir)/manifest.json"))
        _ = model.endEdit(force: true)
        NSApp.terminate(nil)
    }

    /// Types into the search field one key at a time, a frame per key.
    private func type(_ text: String) async {
        for ch in text {
            model.query.append(ch)
            await shot(85, settle: 140)
        }
    }

    /// In tidepool's worker.go: maxBackoff 30s → 60s.
    private func editRetryCap() async {
        guard let tv = editorTextView else { return }
        let range = (tv.string as NSString).range(of: "30 * time.Second")
        guard range.location != NSNotFound else { return }
        tv.setSelectedRange(NSRange(location: range.location, length: 2))
        await shot(700, settle: 100)
        for ch in "60" {
            tv.insertText(String(ch), replacementRange: tv.selectedRange())
            await shot(160, settle: 60)
        }
        await shot(900)
    }

    // MARK: Frames

    private func shot(_ ms: Int, key: String? = nil, settle: Int = 0) async {
        if settle > 0 { await wait(settle) }
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = String(format: "frame_%04d.png", frames.count)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        // Every path on screen, so record.sh can refuse to build a video showing anything outside the scope.
        var paths = model.items.map(\.path)
        if let session = model.editSession { paths.append(session.path) }
        var frame: [String: Any] = ["file": name, "ms": ms, "caption": caption, "paths": paths]
        if let key { frame["key"] = key }
        frames.append(frame)
    }

    private func wait(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private var editorTextView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, !tv.isFieldEditor, tv.enclosingScrollView?.verticalRulerView != nil { return tv }
            for sub in view.subviews { if let tv = find(sub) { return tv } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }
}
