import AppKit
import CoreText
import SwiftUI

/// Gruvbox Dark, as Ghostty ships it, in JetBrains Mono (Ghostty's built-in default font).
enum Theme {
    // Surfaces, darkest to lightest.
    static let bg = Color(hex: 0x282828)        // background
    static let surface = Color(hex: 0x32302F)   // preview pane, footer
    static let raised = Color(hex: 0x3C3836)    // selected row, chips
    static let rule = Color(hex: 0x504945)      // dividers, outlines

    // Text.
    static let fg = Color(hex: 0xEBDBB2)        // foreground
    static let muted = Color(hex: 0xA89984)     // palette 7
    static let faint = Color(hex: 0x928374)     // palette 8

    // Accents.
    static let accent = Color(hex: 0xD79921)    // palette 3: selection bar, active tab
    static let yellow = Color(hex: 0xFABD2F)    // palette 11: matched text
    static let red = Color(hex: 0xFB4934)       // palette 9
    static let green = Color(hex: 0xB8BB26)     // palette 10
    static let aqua = Color(hex: 0x8EC07C)      // palette 14
    static let blue = Color(hex: 0x83A598)      // palette 12
    static let purple = Color(hex: 0xD3869B)    // palette 13
    static let highlight = Color(hex: 0x504945) // behind matched text

    static let family = "JetBrains Mono"

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(size, weight)
    }

    /// The ferret-in-a-lens template for the menu bar; macOS tints it. SF Symbol fallback under `swift run`.
    static let menuBarIcon = templateImage("MenuBarIcon", size: 18, fallback: "magnifyingglass", label: "Ferret")
    static let githubMark = templateImage("GitHubMark", size: 16, fallback: "link", label: "GitHub")

    /// A PNG from Resources (the bundle, or the source tree under `swift run`), tinted like an SF Symbol.
    private static func templateImage(_ name: String, size: CGFloat, fallback: String, label: String) -> NSImage {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).png")
        let image = Bundle.main.image(forResource: name)
            ?? NSImage(contentsOf: source)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: label)!
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// Registers the bundled JetBrains Mono for this process. Falls back to the source tree under `swift run`.
    static func registerFonts() {
        let bundled = Bundle.main.url(forResource: "JetBrainsMono", withExtension: "ttf")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/JetBrainsMono.ttf")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
