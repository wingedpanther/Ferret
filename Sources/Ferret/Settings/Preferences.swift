import AppKit
import Carbon.HIToolbox

enum Editor: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, ttt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .ttt: return "ttt"
        }
    }

    /// ttt is a terminal editor, so it opens inside the chosen terminal.
    var runsInTerminal: Bool { self == .ttt }

    /// CLI paths in the order they're tried. GUI apps don't inherit the shell's PATH.
    var candidates: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .vscode: return ["/opt/homebrew/bin/code", "/usr/local/bin/code",
                              "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]
        case .cursor: return ["/opt/homebrew/bin/cursor", "/usr/local/bin/cursor",
                              "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"]
        case .zed: return ["/opt/homebrew/bin/zed", "/usr/local/bin/zed",
                           "/Applications/Zed.app/Contents/MacOS/cli"]
        case .ttt: return ["/opt/homebrew/bin/ttt", "/usr/local/bin/ttt", "\(home)/.local/bin/ttt", "\(home)/go/bin/ttt"]
        }
    }

    private var bundleID: String? {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        case .ttt: return nil
        }
    }

    var cli: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// The app bundle, for GUI editors whose CLI isn't installed.
    var appURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    var installed: Bool { cli != nil || appURL != nil }

    /// Arguments that open `path`, at a line and column when given. `root` is the project to open around it.
    func arguments(path: String, line: Int?, column: Int?, root: String?) -> [String] {
        let target = line.map { "\(path):\($0):\(column ?? 1)" } ?? path
        switch self {
        case .vscode, .cursor: return line == nil ? [path] : ["-g", target]
        case .zed: return [target]
        case .ttt: return root.map { $0 == path ? [target] : [$0, target] } ?? [target]
        }
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, ghostty, iterm

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .iterm: return "iTerm"
        }
    }
    var bundlePath: String {
        switch self {
        case .terminal: return "/System/Applications/Utilities/Terminal.app"
        case .ghostty: return "/Applications/Ghostty.app"
        case .iterm: return "/Applications/iTerm.app"
        }
    }
    var installed: Bool { FileManager.default.fileExists(atPath: bundlePath) }

    /// Runs `command` in a new window of this terminal, starting in `dir`. It goes through a login zsh
    /// so it gets the user's PATH: ttt needs Homebrew's rg and git, which an app's environment lacks.
    func run(_ command: [String], in dir: String) {
        if self == .ghostty {
            // Ghostty ignores --working-directory with -e, so the shell changes directory itself.
            Actions.run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lc",
                                          #"cd "$1" && shift && exec "$@""#, "zsh", dir] + command)
            return
        }
        // Terminal and iTerm run a .command file they're asked to open.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferret-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh -l\ncd \(shellQuote(dir)) && exec \(command.map(shellQuote).joined(separator: " "))\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return }
        Actions.run("/usr/bin/open", ["-a", self == .iterm ? "iTerm" : "Terminal", script.path])
    }

    /// `open` arguments that start a shell in `dir`.
    func openArguments(dir: String) -> [String] {
        switch self {
        case .terminal: return ["-a", "Terminal", dir]
        case .iterm: return ["-a", "iTerm", dir]
        case .ghostty: return ["-na", "Ghostty", "--args", "--working-directory=\(dir)"]
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, commandShiftSpace, optionCommandSpace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .commandShiftSpace: return "⇧⌘ Space"
        case .optionCommandSpace: return "⌥⌘ Space"
        }
    }
    var keyCode: UInt32 { UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlSpace: return UInt32(controlKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .optionCommandSpace: return UInt32(optionKey | cmdKey)
        }
    }
}

enum Prefs {
    static let editorKey = "editor"
    static let terminalKey = "terminal"
    static let hotKeyKey = "hotkey"
    static let fdaDismissedKey = "fdaBannerDismissed"
    static let repoURL = URL(string: "https://github.com/wingedpanther/ferret")!

    static var editor: Editor {
        Editor(rawValue: UserDefaults.standard.string(forKey: editorKey) ?? "") ?? .vscode
    }
    /// The chosen editor when it's installed, else the first one that is. Nil means use the default app.
    static var resolvedEditor: Editor? {
        editor.installed ? editor : Editor.allCases.first(where: \.installed)
    }
    static var terminal: TerminalApp {
        if let t = TerminalApp(rawValue: UserDefaults.standard.string(forKey: terminalKey) ?? "") { return t }
        return TerminalApp.ghostty.installed ? .ghostty : .terminal
    }
    static var hotKey: HotKeyPreset {
        HotKeyPreset(rawValue: UserDefaults.standard.string(forKey: hotKeyKey) ?? "") ?? .optionSpace
    }
}
