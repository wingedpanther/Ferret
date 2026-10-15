import AppKit

/// What can be done with a result. Each returns quickly; slow work runs in a child process.
enum Actions {
    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens in the chosen editor, at a line when given. A missing editor falls back to another
    /// installed one, then to the file's default app.
    static func openInEditor(_ path: String, line: Int? = nil, column: Int? = nil) {
        guard let editor = Prefs.resolvedEditor else { return open(path) }
        let root = gitRoot(of: path)
        if editor.runsInTerminal, let cli = editor.cli {
            Prefs.terminal.run([cli] + editor.arguments(path: path, line: line, column: column, root: root),
                               in: root ?? directory(of: path))
        } else if let cli = editor.cli {
            run(cli, editor.arguments(path: path, line: line, column: column, root: root))
        } else if let app = editor.appURL {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The enclosing git work tree, so terminal editors open the whole project around a file.
    static func gitRoot(of path: String) -> String? {
        var dir = directory(of: path)
        while dir != "/" && dir != NSHomeDirectory() {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func directory(of path: String) -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
    }

    static func openTerminal(at path: String) {
        run("/usr/bin/open", Prefs.terminal.openArguments(dir: directory(of: path)))
    }

    /// Runs a command without waiting; returns its output to `done` if given.
    static func run(_ tool: String, _ args: [String], done: ((Int32, String) -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { done?(proc.terminationStatus, out) }
        }
        do { try p.run() } catch { done?(-1, error.localizedDescription) }
    }
}
