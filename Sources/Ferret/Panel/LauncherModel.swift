import AppKit
import FSearchKit
import SwiftUI

enum Mode: Int, CaseIterable, Identifiable {
    case files, grep, symbols, git, recent

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .files: return "Files"
        case .grep: return "Grep"
        case .symbols: return "Symbols"
        case .git: return "Git"
        case .recent: return "Recent"
        }
    }
    /// Typing this as the first character switches to the mode.
    var prefix: Character? {
        switch self {
        case .grep: return "/"
        case .symbols: return "#"
        case .git: return "!"
        default: return nil
        }
    }
    var placeholder: String {
        switch self {
        case .files: return "Search files — typos are fine, try ext:pdf or in:~/Developer"
        case .grep: return "Search inside files — ext:swift in:~/Developer or regex:…"
        case .symbols: return "Find a definition — a function, class or type name"
        case .git: return "Filter repos by name — ↩ shows what's changed"
        case .recent: return "Files you opened recently or edited in the last 3 days"
        }
    }
}

struct Repo: Hashable {
    let path: String
    let mtime: Int
    var changed: Int?
    var name: String { (path as NSString).lastPathComponent }
}

enum Item: Identifiable, Hashable {
    case file(Hit)
    case match(path: String, git: String?, GrepMatch)
    case repo(Repo)

    var id: String {
        switch self {
        case .file(let h): return "f:" + h.path
        case .match(let path, _, let m): return "m:\(path):\(m.line):\(m.col)"
        case .repo(let r): return "r:" + r.path
        }
    }
    var path: String {
        switch self {
        case .file(let h): return h.path
        case .match(let path, _, _): return path
        case .repo(let r): return r.path
        }
    }
}

struct Banner: Equatable {
    enum Kind { case indexing, fullDiskAccess, error }
    let kind: Kind
    let text: String
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published var mode: Mode = .files { didSet { if mode != oldValue { modeChanged() } } }
    @Published private(set) var items: [Item] = []
    @Published var selection = 0
    @Published private(set) var busy = false
    @Published private(set) var message: String?        // shown when there are no items
    @Published private(set) var banner: Banner?
    @Published private(set) var footer = ""
    @Published private(set) var repoFocus: Repo?
    @Published private(set) var focusToken = 0          // bumps to refocus the search field
    @Published private(set) var editSession: EditSession?   // set while quick-editing a file (⌘E)
    @Published private(set) var notice: String?          // a one-off note in the footer, e.g. why ⌘E can't edit

    let client = FSearchClient()
    /// Repo status lookups run on their own connection so they never queue behind typing.
    private let gitClient = FSearchClient()

    private var inFlight = false
    private var dirty = false
    private var repos: [Repo] = []
    private var reposLoadedAt = Date.distantPast
    private var lastOpened: String?
    private var lastTook: Int?

    var selected: Item? { items.indices.contains(selection) ? items[selection] : nil }

    // MARK: Lifecycle

    func willShow() {
        focusToken += 1
        Task { await refreshStatus() }
        if mode == .git || Date().timeIntervalSince(reposLoadedAt) > 60 { Task { await loadRepos() } }
        refresh()
    }

    func reset() {
        // Unsaved quick edits survive the panel closing; they're there when it reopens.
        if editSession?.isDirty != true { editSession = nil }
        repoFocus = nil
        query = ""
        mode = .files
    }

    private func queryChanged() {
        if query.count == 1, let c = query.first, let m = Mode.allCases.first(where: { $0.prefix == c }) {
            query = ""
            mode = m
            return
        }
        refresh()
    }

    private func modeChanged() {
        repoFocus = nil
        if mode == .git, repos.isEmpty { Task { await loadRepos() } }
        refresh()
    }

    func cycleMode(_ step: Int) {
        let all = Mode.allCases
        mode = all[(mode.rawValue + step + all.count) % all.count]
    }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + step))
    }

    // MARK: Fetching

    // MARK: Quick edit

    /// ⌘E: edit the selected file in the panel, at the match when there is one.
    func startEdit() {
        guard let item = selected else { return }
        do {
            switch item {
            case .file(let hit):
                editSession = try EditSession(path: hit.path)
            case .match(let path, _, let m):
                // Columns in the editor are UTF-16 offsets into the line; fsearch gives byte ranges.
                let r = m.stringRanges.first
                let column = r.map { m.text.utf16.distance(from: m.text.startIndex, to: $0.lowerBound) } ?? 0
                editSession = try EditSession(path: path, line: m.line,
                                              match: (column, r.map { m.text[$0].utf16.count } ?? 0))
            case .repo:
                throw EditSession.OpenError.folder
            }
            Task { await client.opened(item.path) }
        } catch {
            notice = error.localizedDescription
            updateFooter()
        }
    }

    /// Esc while editing. False when unsaved changes need a second Esc.
    func endEdit(force: Bool = false) -> Bool {
        guard let session = editSession else { return true }
        guard force || session.confirmClose() else { return false }
        editSession = nil
        focusToken += 1
        refresh()          // the file may have changed what matches
        return true
    }

    /// ⌥↩ while editing: hand over to the full editor at the cursor. Unsaved changes must be saved first.
    func openEditSessionInEditor() -> Bool {
        guard let session = editSession else { return false }
        if session.isDirty {
            session.message = "Save first (⌘S) — the editor would open the old version."
            return false
        }
        Actions.openInEditor(session.path, line: session.cursor.line, column: session.cursor.column)
        _ = endEdit(force: true)
        return true
    }

    /// Latest wins: while a request is out, further keystrokes only mark the results stale,
    /// and one more request goes out when it returns.
    func refresh() {
        if inFlight { dirty = true; return }
        inFlight = true
        busy = true
        Task {
            repeat {
                dirty = false
                let (mode, query, focus) = (self.mode, self.query, self.repoFocus)
                let started = Date()
                let result: Result<[Item], Error>
                do { result = .success(try await fetch(mode: mode, query: query, focus: focus)) } catch { result = .failure(error) }
                if !dirty { apply(result, mode: mode, query: query, elapsed: Date().timeIntervalSince(started)) }
            } while dirty
            inFlight = false
            busy = false
        }
    }

    private func apply(_ result: Result<[Item], Error>, mode: Mode, query: String, elapsed: TimeInterval) {
        let keep = selected?.id
        notice = nil
        switch result {
        case .success(let new):
            items = new
            message = new.isEmpty ? emptyMessage(mode: mode, query: query) : nil
            if !new.isEmpty, case .indexing = banner?.kind { Task { await refreshStatus() } }
        case .failure(let error):
            items = []
            message = error.localizedDescription
            if error.localizedDescription.contains("indexing") {
                banner = Banner(kind: .indexing, text: error.localizedDescription)
            }
        }
        // Keep the highlighted row when it survived (repo counts arriving), otherwise go to the top.
        selection = keep.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        lastTook = Int(elapsed * 1000)
        updateFooter()
    }

    private func emptyMessage(mode: Mode, query: String) -> String {
        switch mode {
        case .grep where query.isEmpty, .symbols where query.isEmpty:
            return "Type to search inside every text and code file in your home folder."
        case .git where repoFocus != nil:
            return "Nothing changed in \(repoFocus!.name)."
        default:
            return query.isEmpty ? "Nothing here yet." : "No matches for “\(query)”."
        }
    }

    private func fetch(mode: Mode, query: String, focus: Repo?) async throws -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .files:
            if q.isEmpty { return try await recentItems(filter: "") }
            var extra: [String: Any] = ["boost": true, "git": true]
            if let lastOpened { extra["near"] = lastOpened }
            return try await client.search(q, limit: 60, extra: extra).map(Item.file)

        case .grep, .symbols:
            guard let parsed = GrepQuery(q), !parsed.pattern.isEmpty else { return [] }
            var extra = parsed.filters
            extra["git"] = true
            extra["defs"] = true
            extra["budget_ms"] = 150
            let reply: GrepReply
            if mode == .symbols {
                extra["after"] = 8
                extra["per_file"] = 3
                reply = try await client.grep(parsed.pattern, mode: "symbol", limit: 50, extra: extra)
            } else {
                extra["context"] = 2
                extra["per_file"] = 5
                reply = try await client.grep(parsed.pattern, mode: parsed.regex ? "regex" : "literal", limit: 30, extra: extra)
            }
            return (reply.files ?? []).flatMap { f in f.matches.map { Item.match(path: f.path, git: f.git, $0) } }

        case .git:
            if let focus {
                let hits = try await client.search("git:modified", limit: 300, extra: ["in": focus.path, "git": true])
                return hits.filter { q.isEmpty || $0.path.localizedCaseInsensitiveContains(q) }.map(Item.file)
            }
            let words = q.lowercased().split(separator: " ")
            return repos
                .filter { r in words.allSatisfy { r.path.lowercased().contains($0) } }
                .sorted { ($0.changed ?? 0 > 0 ? 1 : 0, $0.mtime) > ($1.changed ?? 0 > 0 ? 1 : 0, $1.mtime) }
                .map(Item.repo)

        case .recent:
            return try await recentItems(filter: q)
        }
    }

    /// Files fsearch saw you open (frecency), then whatever changed in your home folder in the last three days.
    private func recentItems(filter: String) async throws -> [Item] {
        let opened = try await client.recent(filter, limit: 40, extra: ["git": true])
        let skip = "!Library !node_modules !.git !.cache !.Trash !DerivedData !.build !target"
        let touched = try await client.search("in:~ mtime:<3d kind:file \(skip) \(filter)", limit: 300, extra: ["git": true, "ignored": false])
            .sorted { $0.mtime > $1.mtime }
        var seen = Set<String>()
        return (opened + touched).filter { seen.insert($0.path).inserted }.prefix(120).map(Item.file)
    }

    // MARK: Repos

    private func loadRepos() async {
        guard let hits = try? await client.search(#"re:^\.git$ kind:dir in:~"#, limit: 5000) else { return }
        let junk = ["/Library/", "/node_modules/", "/.cargo/", "/.cache/", "/go/pkg/", "/.Trash/", "/.local/share/", "/.npm/", "/.rustup/"]
        let known = Dictionary(repos.map { ($0.path, $0.changed) }, uniquingKeysWith: { a, _ in a })
        repos = hits
            .filter { h in h.path.hasSuffix("/.git") && !junk.contains { h.path.contains($0) } }
            .map { Repo(path: $0.parent, mtime: $0.mtime, changed: known[$0.parent] ?? nil) }
            .sorted { $0.mtime > $1.mtime }
        reposLoadedAt = Date()
        if mode == .git { refresh() }
        await loadChangedCounts()
    }

    /// fsearch answers `read:false` the first time it's asked about a repo while it reads git status, so ask twice more.
    private func loadChangedCounts() async {
        var pending = repos.map(\.path)
        for attempt in 0..<3 {
            var unread: [String] = []
            for path in pending {
                guard let reply = try? await gitClient.git(path) else { continue }
                if reply.read == false || reply.changed == nil { unread.append(path); continue }
                if let i = repos.firstIndex(where: { $0.path == path }) { repos[i].changed = reply.changed }
            }
            if mode == .git, repoFocus == nil { refresh() }
            pending = unread
            if pending.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 1500))
        }
    }

    // MARK: Actions

    /// ↩: open the file, jump to the line, or look inside a repo.
    func primary() -> Bool {
        guard let item = selected else { return false }
        switch item {
        case .file(let h):
            Actions.open(h.path)
            didOpen(h.path)
        case .match(let path, _, let m):
            Actions.openInEditor(path, line: m.line, column: m.column)
            didOpen(path)
        case .repo(let r):
            repoFocus = r
            query = ""
            refresh()
            return false
        }
        return true
    }

    /// ⌥↩: open in the editor, at the line for matches.
    func openInEditor() -> Bool {
        guard let item = selected else { return false }
        if case .match(let path, _, let m) = item {
            Actions.openInEditor(path, line: m.line, column: m.column)
        } else {
            Actions.openInEditor(item.path)
        }
        didOpen(item.path)
        return true
    }

    func reveal() -> Bool {
        guard let item = selected else { return false }
        Actions.reveal(item.path)
        return true
    }

    func openTerminal() -> Bool {
        guard let item = selected else { return false }
        Actions.openTerminal(at: item.path)
        return true
    }

    func copyPath() {
        if let item = selected { Actions.copy(item.path) }
    }

    /// ← or Esc inside a repo goes back to the repo list.
    func leaveRepo() -> Bool {
        guard let focus = repoFocus else { return false }
        repoFocus = nil
        query = ""
        refresh()
        if let i = items.firstIndex(where: { $0.path == focus.path }) { selection = i }
        return true
    }

    private func didOpen(_ path: String) {
        lastOpened = path
        Task { await client.opened(path) }
    }

    // MARK: Status

    func refreshStatus() async {
        guard let s = try? await client.status() else {
            banner = Banner(kind: .error, text: "Can't start fsearch from \(Format.path(FSearchClient.binary)). Rebuild Ferret with scripts/bundle.sh to include it.")
            return
        }
        if !s.ok {
            banner = Banner(kind: .indexing, text: s.error ?? "fsearch is indexing")
        } else if s.full_disk_access == false, !UserDefaults.standard.bool(forKey: Prefs.fdaDismissedKey) {
            banner = Banner(kind: .fullDiskAccess, text: FSearchClient.isUsingBundled
                            ? "Give Ferret Full Disk Access to search Desktop, Documents and Downloads."
                            : "fsearch can't see Desktop, Documents or Downloads without Full Disk Access.")
        } else {
            banner = nil
        }
        statusLine = s.ok ? "\(compact(s.entries ?? 0)) files · \(compact(s.content_docs ?? 0)) searchable inside" : ""
        updateFooter()
    }

    func dismissBanner() {
        if banner?.kind == .fullDiskAccess { UserDefaults.standard.set(true, forKey: Prefs.fdaDismissedKey) }
        banner = nil
    }

    private var statusLine = ""

    private func updateFooter() {
        if let notice { footer = notice; return }
        var parts = [statusLine].filter { !$0.isEmpty }
        if let lastTook { parts.append(lastTook == 0 ? "<1 ms" : "\(lastTook) ms") }
        footer = parts.joined(separator: " · ")
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// Splits `ext:swift in:~/Dev some text` into fsearch filter fields and the pattern to grep.
struct GrepQuery {
    static let filterKeys: Set<String> = ["ext", "in", "type", "kind", "size", "mtime", "path", "re", "glob"]

    var pattern = ""
    var regex = false
    var filters: [String: Any] = [:]

    init?(_ query: String) {
        var words: [Substring] = []
        for word in query.split(separator: " ", omittingEmptySubsequences: true) {
            if let colon = word.firstIndex(of: ":") {
                let key = String(word[..<colon]), value = String(word[word.index(after: colon)...])
                if key == "regex", !value.isEmpty { regex = true; words.append(Substring(value)); continue }
                if Self.filterKeys.contains(key), !value.isEmpty { filters[key] = value; continue }
            }
            words.append(word)
        }
        pattern = words.joined(separator: " ")
    }
}
