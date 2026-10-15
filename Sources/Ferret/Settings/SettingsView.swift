import FSearchKit
import SwiftUI

struct SettingsView: View {
    let client: FSearchClient
    let hotKeyChanged: () -> Void

    @AppStorage(Prefs.hotKeyKey) private var hotKey = HotKeyPreset.optionSpace.rawValue
    @AppStorage(Prefs.editorKey) private var editor = Editor.vscode.rawValue
    @AppStorage(Prefs.terminalKey) private var terminal = Prefs.terminal.rawValue
    @State private var status: Status?
    @State private var loginOutput: String?
    @State private var installing = false
    @State private var tttInstall: String?          // progress or result of installing ttt
    @State private var refresh = 0                  // bumps after an install so availability re-checks

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Ferret").font(Theme.font(24, .bold)).foregroundStyle(Theme.accent)
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text(version).font(Theme.font(12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Link(destination: Prefs.repoURL) {
                        HStack(spacing: 6) {
                            Image(nsImage: Theme.githubMark).renderingMode(.template).resizable().frame(width: 14, height: 14)
                            Text("wingedpanther/ferret").font(Theme.font(12))
                        }
                        .foregroundStyle(Theme.blue)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    .help(Prefs.repoURL.absoluteString)
                }
            }

            Section(title: "Shortcuts and apps") {
                Row(label: "Open the launcher") {
                    Picker("", selection: $hotKey) {
                        ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: hotKey) { hotKeyChanged() }
                }
                Row(label: "Code editor") {
                    Picker("", selection: $editor) {
                        ForEach(Editor.allCases) { e in
                            Text(e.installed ? e.title : "\(e.title) (not installed)").tag(e.rawValue)
                        }
                    }
                    .id(refresh)
                }
                editorAvailability
                Row(label: "Terminal") {
                    Picker("", selection: $terminal) {
                        ForEach(TerminalApp.allCases.filter(\.installed)) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }

            Section(title: "fsearch") {
                if let status {
                    Row(label: "Indexed") {
                        Text("\((status.entries ?? 0).formatted()) files and folders · \((status.content_docs ?? 0).formatted()) searchable inside")
                            .font(Theme.font(12)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                    }
                    Row(label: "Full Disk Access") {
                        Text(status.full_disk_access == true ? "Yes" : "No — Desktop, Documents and Downloads are skipped")
                            .font(Theme.font(12)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Can't reach fsearch at \(Format.path(FSearchClient.binary)).")
                        .font(Theme.font(12)).foregroundStyle(Theme.fg)
                }
                Row(label: "Using") {
                    Text(FSearchClient.isUsingBundled ? "the copy inside Ferret" : Format.path(FSearchClient.binary))
                        .font(Theme.font(12)).foregroundStyle(Theme.fg)
                }
                Text(FSearchClient.isUsingBundled
                     ? "fsearch isn't installed, so Ferret runs its own copy. Give Ferret Full Disk Access to index Desktop, Documents and Downloads. Install fsearch below to start it at login."
                     : "To index Desktop, Documents and Downloads, open Full Disk Access. Drag fsearch in from Finder and switch it on. Then click Run fsearch at login to restart it with access. Each fsearch rebuild needs the grant again.")
                    .font(Theme.font(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                // In the order the steps above give them.
                HStack(spacing: 10) {
                    ThemeButton(title: "Open Full Disk Access", primary: false) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    if !FSearchClient.isUsingBundled {
                        // ~/.local is hidden, so the Full Disk Access file picker won't show it without ⌘⇧G.
                        ThemeButton(title: "Show in Finder", primary: false) { Actions.reveal(FSearchClient.binary) }
                    }
                }
                ThemeButton(title: installing ? "Setting up…" : FSearchClient.isUsingBundled ? "Install fsearch" : "Run fsearch at login",
                            primary: true) {
                    installing = true
                    Actions.run(FSearchClient.binary, ["install", "--login"]) { code, out in
                        installing = false
                        loginOutput = code == 0 ? "Done. fsearch now starts at login." : out
                        Task { status = try? await client.status() }
                    }
                }
                if let loginOutput {
                    Text(loginOutput).font(Theme.font(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(width: 560, height: 640, alignment: .topLeading)
        .background(Theme.bg)
        .task { status = try? await client.status() }
    }
}

extension SettingsView {
    /// Says what happens when the chosen editor is missing, and offers to install ttt.
    @ViewBuilder var editorAvailability: some View {
        let chosen = Editor(rawValue: editor) ?? .vscode
        let _ = refresh
        if !chosen.installed {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(chosen.title) isn't installed, so files open in \(Prefs.resolvedEditor?.title ?? "their default app").")
                    .font(Theme.font(12)).foregroundStyle(Theme.yellow).fixedSize(horizontal: false, vertical: true)
                if chosen == .ttt {
                    if let brew = Installer.brew {
                        ThemeButton(title: tttInstall == "installing" ? "Installing ttt…" : "Install ttt with Homebrew", primary: true) {
                            guard tttInstall != "installing" else { return }
                            tttInstall = "installing"
                            Installer.installTTT(brew: brew) { ok, output in
                                tttInstall = ok ? nil : output
                                refresh += 1
                            }
                        }
                    } else {
                        ThemeButton(title: "Download ttt", primary: true) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/eugenioenko/ttt/releases/latest")!)
                        }
                    }
                }
                if let tttInstall, tttInstall != "installing" {
                    ScrollView { Text(tttInstall).font(Theme.font(10)).foregroundStyle(Theme.muted).textSelection(.enabled) }
                        .frame(maxHeight: 80)
                }
            }
        } else if chosen.runsInTerminal {
            Text("ttt opens in \(Prefs.terminal.title), with the file's git repo as the project.")
                .font(Theme.font(12)).foregroundStyle(Theme.muted)
        }
    }
}

enum Installer {
    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The steps ttt's README gives for Homebrew. Runs in a login shell for the user's PATH.
    static func installTTT(brew: String, done: @escaping (Bool, String) -> Void) {
        let b = shellQuote(brew)
        let script = "\(b) tap eugenioenko/ttt && \(b) trust eugenioenko/ttt && \(b) install ttt"
        Actions.run("/bin/zsh", ["-lc", script]) { code, out in
            done(code == 0 && Editor.ttt.installed, code == 0 ? out : "Install failed:\n" + out)
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.fg)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        }
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label).font(Theme.font(12, .medium)).foregroundStyle(Theme.fg).frame(width: 130, alignment: .leading)
            content.labelsHidden()
            Spacer(minLength: 0)
        }
    }
}

private struct ThemeButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.font(12, .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(primary ? Theme.bg : Theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(primary ? Theme.accent : Theme.bg))
                .overlay(Capsule().stroke(primary ? Color.clear : Theme.fg.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }
}
