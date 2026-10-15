import FSearchKit
import QuickLookThumbnailing
import SwiftUI

/// The right-hand pane: a thumbnail and details for files, the surrounding lines for matches.
struct PreviewPane: View {
    let item: Item?

    var body: some View {
        Group {
            switch item {
            case .file(let hit)?: FilePreview(hit: hit)
            case .match(let path, let git, let m)?: MatchPreview(path: path, git: git, match: m)
            case .repo(let repo)?: RepoPreview(repo: repo)
            case nil: Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
    }
}

private struct FilePreview: View {
    let hit: Hit
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    FileIcon(path: hit.path).frame(width: 72, height: 72)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 170)

            Text(hit.name).font(Theme.font(14, .semibold)).foregroundStyle(Theme.fg).lineLimit(2)
            VStack(alignment: .leading, spacing: 6) {
                Detail(label: "Where", value: Format.path(hit.parent))
                if !hit.isDir { Detail(label: "Size", value: Format.size(hit.size)) }
                Detail(label: "Modified", value: hit.modified.formatted(date: .abbreviated, time: .shortened))
                if let git = hit.git { Detail(label: "Git", value: git) }
            }
            Spacer()
        }
        .padding(16)
        .task(id: hit.path) { thumbnail = await Self.thumbnail(for: hit.path) }
    }

    static func thumbnail(for path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 340, height: 340),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

private struct MatchPreview: View {
    let path: String
    let git: String?
    let match: GrepMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent).font(Theme.font(14, .semibold)).foregroundStyle(Theme.fg)
                if let git { GitBadge(status: git) }
            }
            Text(Format.path((path as NSString).deletingLastPathComponent))
                .font(Theme.font(11)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.head)

            ScrollView([.horizontal]) {
                VStack(alignment: .leading, spacing: 2) {
                    let before = match.before ?? []
                    ForEach(Array(before.enumerated()), id: \.offset) { i, line in
                        CodeLine(number: match.line - before.count + i, text: line)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        LineNumber(n: match.line, current: true)
                        Highlighted(match: match, size: 11.5)
                    }
                    ForEach(Array((match.after ?? []).enumerated()), id: \.offset) { i, line in
                        CodeLine(number: match.line + 1 + i, text: line)
                    }
                }
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
            Spacer()
        }
        .padding(16)
    }
}

private struct CodeLine: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LineNumber(n: number, current: false)
            Text(text.isEmpty ? " " : text).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
        }
    }
}

private struct LineNumber: View {
    let n: Int
    let current: Bool
    var body: some View {
        Text(verbatim: String(n)).font(Theme.mono(10.5, current ? .bold : .regular))
            .foregroundStyle(current ? Theme.accent : Theme.fg.opacity(0.4))
            .frame(minWidth: 30, alignment: .trailing)
    }
}

private struct RepoPreview: View {
    let repo: Repo
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 44)).foregroundStyle(Theme.blue)
            Text(repo.name).font(Theme.font(15, .semibold)).foregroundStyle(Theme.fg)
            VStack(alignment: .leading, spacing: 6) {
                Detail(label: "Where", value: Format.path(repo.path))
                Detail(label: "Changes", value: repo.changed.map { $0 == 0 ? "clean" : "\($0) files" } ?? "checking…")
                Detail(label: "Last git activity", value: Format.age(Date(timeIntervalSince1970: TimeInterval(repo.mtime))))
            }
            Text("↩ see changed files   ⌥↩ open in editor   ⌘T terminal")
                .font(Theme.font(11)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(16)
    }
}

private struct Detail: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(Theme.font(9, .bold)).foregroundStyle(Theme.muted).kerning(0.6)
            Text(value).font(Theme.font(12)).foregroundStyle(Theme.fg).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
