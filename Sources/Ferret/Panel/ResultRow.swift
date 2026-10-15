import AppKit
import FSearchKit
import SwiftUI

struct ResultRow: View {
    let item: Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.raised : Theme.bg)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .file(let hit):
            FileIcon(path: hit.path).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name).font(Theme.font(13, .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(Format.path(hit.parent)).font(Theme.font(11)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let git = hit.git { GitBadge(status: git) }
            Text(Format.age(hit.modified)).font(Theme.font(11)).foregroundStyle(Theme.muted)
                .frame(minWidth: 44, alignment: .trailing)

        case .match(let path, let git, let m):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((path as NSString).lastPathComponent).font(Theme.font(11, .semibold)).foregroundStyle(Theme.fg)
                    Text(verbatim: ":" + String(m.line)).font(Theme.font(11)).foregroundStyle(Theme.muted)
                    if m.def == true { Tag(text: "definition") }
                    if let git { GitBadge(status: git) }
                    Spacer(minLength: 0)
                    Text(Format.path((path as NSString).deletingLastPathComponent))
                        .font(Theme.font(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                }
                Highlighted(match: m, size: 12).lineLimit(1)
            }

        case .repo(let repo):
            Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(Theme.blue).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(Theme.font(13, .semibold)).foregroundStyle(Theme.fg)
                Text(Format.path((repo.path as NSString).deletingLastPathComponent)).font(Theme.font(11))
                    .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            switch repo.changed {
            case nil: ProgressView().controlSize(.mini)
            case 0?: Text("clean").font(Theme.font(11)).foregroundStyle(Theme.muted)
            case let n?: Tag(text: "\(n) changed", strong: true)
            }
        }
    }
}

/// A matched line with fsearch's byte ranges picked out in yellow.
struct Highlighted: View {
    let match: GrepMatch
    let size: CGFloat

    var body: some View {
        Text(attributed).font(Theme.mono(size)).foregroundStyle(Theme.fg)
    }

    private var attributed: AttributedString {
        let text = match.text
        // Trim leading indentation so the match stays in view.
        let indent = text.prefix { $0 == " " || $0 == "\t" }
        var out = AttributedString()
        var cursor = indent.endIndex
        for r in match.stringRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= cursor {
            out += AttributedString(text[cursor..<r.lowerBound])
            var mark = AttributedString(text[r])
            mark.backgroundColor = Theme.highlight
            mark.foregroundColor = Theme.yellow
            mark.font = Theme.mono(size, .bold)
            out += mark
            cursor = r.upperBound
        }
        out += AttributedString(text[cursor...])
        return out
    }
}

struct GitBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(Theme.font(10, .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.6)))
            .help("git: \(status)")
    }

    private var color: Color {
        switch status {
        case "untracked": return Theme.green
        case "staged", "added": return Theme.aqua
        case "renamed": return Theme.blue
        case "deleted", "conflict": return Theme.red
        case "ignored": return Theme.faint
        default: return Theme.yellow
        }
    }

    private var label: String {
        switch status {
        case "untracked": return "U"
        case "staged", "added": return "A"
        case "renamed": return "R"
        case "deleted": return "D"
        case "conflict": return "C"
        case "ignored": return "I"
        default: return "M"
        }
    }
}

struct Tag: View {
    let text: String
    var strong = false

    var body: some View {
        Text(text)
            .font(Theme.font(10, .semibold))
            .foregroundStyle(strong ? Theme.yellow : Theme.fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(strong ? Theme.highlight : Theme.raised))
    }
}

struct FileIcon: View {
    let path: String
    var body: some View { Image(nsImage: IconCache.icon(for: path)).resizable().interpolation(.high) }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func path(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    static func age(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "now" : relative.localizedString(for: date, relativeTo: Date())
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
