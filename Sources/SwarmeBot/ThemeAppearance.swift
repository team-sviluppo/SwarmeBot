// Dynamic colours and the scene modifier behind the dark / light / system choice.
import AppKit
import SwarmeKit
import SwiftUI

extension NSColor {
    /// A colour that resolves to `dark` or `light` by the appearance it is drawn in.
    static func dynamic(dark: String, darkAlpha: CGFloat = 1, light: String, lightAlpha: CGFloat = 1) -> NSColor {
        let darkColor = NSColor(hexString: dark, alpha: darkAlpha)
        let lightColor = NSColor(hexString: light, alpha: lightAlpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    convenience init(hexString: String, alpha: CGFloat = 1) {
        var value: UInt64 = 0
        Scanner(string: hexString.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(dark: String, darkAlpha: CGFloat = 1, light: String, lightAlpha: CGFloat = 1) {
        self.init(nsColor: .dynamic(dark: dark, darkAlpha: darkAlpha, light: light, lightAlpha: lightAlpha))
    }
}

extension AppAppearance {
    /// nil follows macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// Every scene's colour scheme, from the Settings choice.
private struct AppAppearanceModifier: ViewModifier {
    @State private var settings = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(settings.appearance.colorScheme)
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}
