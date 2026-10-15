import AppKit
import SwiftUI

@main
struct FerretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open Ferret") { delegate.panel?.present() }
            if delegate.hotKeyFailed {
                Text("\(Prefs.hotKey.title) is taken by another app — pick another in Settings")
            }
            Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit Ferret") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: Theme.menuBarIcon)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// SwiftUI wraps the delegate, so `NSApp.delegate` isn't this object; reach it here instead.
    private(set) static weak var shared: AppDelegate?
    private(set) var panel: LauncherPanel?
    @Published private(set) var hotKeyFailed = false
    private let model = LauncherModel()
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under `swift run` there's no Info.plist saying LSUIElement, so keep out of the Dock here too.
        NSApp.setActivationPolicy(.accessory)
        Self.shared = self
        Theme.registerFonts()
        panel = LauncherPanel(model: model)
        registerHotKey()
        panel?.present()
        if let panel { Snapshot.run(panel: panel, model: model); Demo.run(panel: panel, model: model) }
    }

    func registerHotKey() {
        let preset = Prefs.hotKey
        hotKey = nil
        hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.panel?.toggle() }
        }
        hotKeyFailed = hotKey == nil
    }

    func showSettings() {
        panel?.dismiss(reset: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Ferret Settings"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SettingsView(client: model.client) { [weak self] in
                self?.registerHotKey()
            })
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
