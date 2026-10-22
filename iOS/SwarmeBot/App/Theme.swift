// The Mac app's palette (Sources/SwarmeBot/Theme.swift, docs/design/grok-style-spec.md)
// with the same names, so the shared mascot files compile here unchanged.
// Dark first, as on the Mac; the light values follow the system's look.
import SwiftUI
import UIKit

enum Theme {
    static let app = Color(dark: "#070707", light: "#FFFFFF")
    static let panel = Color(dark: "#111111", light: "#F4F4F6")
    static let card = Color(dark: "#1C1C1E", light: "#EAEAED")
    static let raised = Color(dark: "#2F2F2F", light: "#E6E6EA")
    static let inset = Color(dark: "#191919", light: "#EFEFF2")
    static let hairline = Color(dark: "#333333", light: "#D6D6DB")
    static let ink = Color(dark: "#FCFCFC", light: "#18181B")
    static let secondary = Color(dark: "#FCFCFC", darkAlpha: 0.6, light: "#18181B", lightAlpha: 0.62)
    static let tertiary = Color(dark: "#FCFCFC", darkAlpha: 0.42, light: "#18181B", lightAlpha: 0.45)
    static let accent = Color(dark: "#1084FE", light: "#0A74E6")
    static let bubbleBot = Color(dark: "#1F1F1F", light: "#F0F0F3")
    static let success = Color(dark: "#38D591", light: "#12A06A")
    static let danger = Color(dark: "#FF5667", light: "#E0334A")
    static let warning = Color(dark: "#FF9800", light: "#D97F00")
    /// The floating pills (search, composer, top bar buttons).
    static let pill = Color(dark: "#2A2A2C", darkAlpha: 0.92, light: "#FFFFFF", lightAlpha: 0.95)
}

extension Color {
    init(dark: String, darkAlpha: Double = 1, light: String, lightAlpha: Double = 1) {
        func ui(_ hex: String, _ alpha: Double) -> UIColor {
            var value: UInt64 = 0
            Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        }
        let darkColor = ui(dark, darkAlpha), lightColor = ui(light, lightAlpha)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}
