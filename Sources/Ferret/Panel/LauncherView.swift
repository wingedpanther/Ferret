import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onAction: (Bool) -> Void          // true when the panel should close
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.editSession {
                EditHeader(session: session).padding(.horizontal, 18).frame(height: 46)
                Rectangle().fill(Theme.rule).frame(height: 1)
                QuickEditView(session: session, focusToken: model.focusToken)
                    .id(session.path)
            } else {
                header
                ModeTabs(mode: $model.mode)
                Rectangle().fill(Theme.rule).frame(height: 1)
                if let banner = model.banner { BannerView(banner: banner, dismiss: model.dismissBanner) }
                HStack(spacing: 0) {
                    results.frame(width: 470)
                    Rectangle().fill(Theme.rule).frame(width: 1)
                    PreviewPane(item: model.selected)
                }
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            footer
        }
        .frame(width: 800, height: 500)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.fg.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let repo = model.repoFocus {
                Button { _ = model.leaveRepo() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(repo.name).font(Theme.font(12, .semibold))
                    }
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.surface))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.fg)
            }
            // Drawn by hand: TextField ignores a prompt's colour, so it read as typed text.
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(placeholder).font(Theme.font(17)).foregroundStyle(Theme.faint).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Theme.font(17, .medium))
                    .foregroundStyle(Theme.fg)
                    .focused($fieldFocused)
            }
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var placeholder: String {
        model.repoFocus.map { "Changed files in \($0.name) — type to filter" } ?? model.mode.placeholder
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ResultRow(item: item, selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture(count: 2) { model.selection = index; onAction(model.primary()) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = index })
                    }
                }
            }
            .overlay {
                if model.items.isEmpty, let message = model.message {
                    Text(message).font(Theme.font(13)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center).padding(30)
                }
            }
            .onChange(of: model.selection) {
                if let item = model.selected { proxy.scrollTo(item.id) }
            }
        }
        .background(Theme.bg)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let session = model.editSession {
                EditFooterStatus(session: session)
            } else {
                Text(model.footer).font(Theme.font(11)).foregroundStyle(model.notice == nil ? Theme.muted : Theme.yellow)
            }
            Spacer()
            ForEach(hints, id: \.0) { key, label in
                HStack(spacing: 4) {
                    Text(key).font(Theme.font(11, .bold)).foregroundStyle(Theme.fg)
                    Text(label).font(Theme.font(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Theme.surface)
    }

    private var hints: [(String, String)] {
        // Name the editor that will actually open, which may be a fallback for a missing one.
        let editor = Prefs.resolvedEditor?.title ?? "Default app"
        if let session = model.editSession {
            let wrap = ("⌥Z", session.wrap ? "No wrap" : "Wrap")
            return session.readOnly ? [("⌘F", "Find"), wrap, ("⌥↩", editor), ("esc", "Close")]
                                    : [("⌘S", "Save"), ("⌘F", "Find"), wrap, ("⌥↩", editor), ("esc", "Close")]
        }
        switch model.selected {
        case .repo?: return [("↩", "Changes"), ("⌥↩", editor), ("⌘T", "Terminal")]
        case .match?: return [("↩", "Line in \(editor)"), ("⌘E", "Quick edit"), ("⌘Y", "Preview"), ("⌘↩", "Reveal")]
        default: return [("↩", "Open"), ("⌘E", "Quick edit"), ("⌥↩", editor), ("⌘↩", "Reveal"), ("⌘Y", "Preview")]
        }
    }
}

private struct ModeTabs: View {
    @Binding var mode: Mode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { m in
                Button { mode = m } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(m.title).font(Theme.font(12, m == mode ? .semibold : .medium))
                            Text(m.prefix.map(String.init) ?? "⌘\(m.rawValue + 1)")
                                .font(Theme.font(10, .medium)).foregroundStyle(Theme.fg.opacity(0.4))
                        }
                        .foregroundStyle(m == mode ? Theme.fg : Theme.fg.opacity(0.6))
                        Rectangle().fill(m == mode ? Theme.accent : .clear).frame(height: 2)
                    }
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Tab to switch").font(Theme.font(10)).foregroundStyle(Theme.fg.opacity(0.4))
        }
        .padding(.horizontal, 12)
    }
}

private struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(banner.kind == .error ? Theme.red : Theme.accent).frame(width: 7, height: 7)
            Text(banner.text).font(Theme.font(12)).foregroundStyle(Theme.fg).lineLimit(2)
            Spacer()
            if banner.kind == .fullDiskAccess {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.fg)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().stroke(Theme.fg.opacity(0.3)))
            }
            if banner.kind != .indexing {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Theme.surface)
    }
}
