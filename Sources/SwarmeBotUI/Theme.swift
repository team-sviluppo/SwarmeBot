// The palette, from `src/styles.css` in the Electron app.
//
// Flat and opaque on purpose: no system vibrancy on the sidebar or the
// inspector. The look is near-black panels with grey bubbles, and a
// translucent sidebar pulls it toward stock macOS and away from that.
//
// Every colour is dynamic: the `dark` value is the original palette, the
// `light` one its counterpart. They resolve by the appearance of the window
// they are drawn in, which the Settings choice (dark, light, system) sets on
// every scene through `appAppearance()`.
import AppKit
import SwarmeKit
import SwiftUI

public enum Theme {
    /// AppKit views (the composer's text view) need an NSColor that stays dynamic;
    /// `NSColor(Color)` would freeze it to the appearance current at the call.
    public static let nsInk = NSColor.dynamic(dark: "#FCFCFC", light: "#18181B")
    public static let nsSecondary = NSColor.dynamic(dark: "#FCFCFC", darkAlpha: 0.6, light: "#18181B", lightAlpha: 0.62)
    /// Quotes and h6 in a bot reply, and the bar beside a quote.
    public static let nsInkSoft = NSColor.dynamic(dark: "#FCFCFC", darkAlpha: 0.85, light: "#18181B", lightAlpha: 0.85)
    public static let nsQuoteBar = NSColor.dynamic(dark: "#FCFCFC", darkAlpha: 0.45, light: "#18181B", lightAlpha: 0.45)
    public static let nsAccent = NSColor.dynamic(dark: "#1084FE", light: "#0A74E6")

    public static let app = Color(dark: "#070707", light: "#FFFFFF")
    public static let panel = Color(dark: "#111111", light: "#F4F4F6")
    public static let card = Color(dark: "#262626", light: "#EAEAED")
    public static let raised = Color(dark: "#2F2F2F", light: "#E6E6EA")
    public static let raisedHover = Color(dark: "#3D3D3D", light: "#D8D8DD")
    /// Old name for `raisedHover`.
    public static var hover: Color { raisedHover }
    public static let inset = Color(dark: "#191919", light: "#EFEFF2")
    public static let hairline = Color(dark: "#333333", light: "#D6D6DB")
    public static let ink = Color(nsColor: nsInk)
    public static let secondary = Color(nsColor: nsSecondary)
    public static let tertiary = Color(dark: "#FCFCFC", darkAlpha: 0.42, light: "#18181B", lightAlpha: 0.45)
    public static let accent = Color(nsColor: nsAccent)
    /// Bubbles as in Grok Bot: the bot's a step above the window, yours a step above that.
    public static let bubbleUser = Color(dark: "#2E2E2E", light: "#E8E8EC")
    public static let bubbleBot = Color(dark: "#1C1C1C", light: "#F3F3F6")
    public static let success = Color(dark: "#38D591", light: "#12A06A")
    public static let danger = Color(dark: "#FF5667", light: "#E0334A")
    public static let warning = Color(dark: "#FF9800", light: "#D97F00")
    public static let accentBorder = Color(dark: "#459FFE", light: "#1084FE")
    public static let focus = Color(dark: "#459FFE", light: "#1084FE")
    public static let accentText = Color(dark: "#7FC0FF", light: "#0A64C8")
    public static let accentInk = Color.white
    public static let dangerInk = Color.white
    public static let scrollbar = Color(dark: "#3D3D3D", light: "#C4C4CA")
    /// Drop shadows: full black on the dark look, softer on the light one.
    public static let shadow = Color(dark: "#000000", light: "#000000", lightAlpha: 0.45)
    /// Behind the command palette.
    public static let scrim = Color.black.opacity(0.5)
    /// The session-limit chip's yellow: orange `warning` reads as yellow on the dark header only.
    public static let caution = Color(dark: "#F5C842", light: "#B58900")

    /// Chat text, matched to Grok Bot: 14 pt regular, ~20 pt line.
    public static let bodySize: CGFloat = 14
    public static let bodyLineSpacing: CGFloat = 3
    /// Sidebar name and composer chrome.
    public static let uiSize: CGFloat = 13
    public static let captionSize: CGFloat = 12
    /// `rounded-xl`
    public static let radius: CGFloat = 12
    /// `rounded-lg`
    public static let smallRadius: CGFloat = 8
    public static let radiusCard: CGFloat = 16
    public static let radiusBubble: CGFloat = 14
    public static let radiusRow: CGFloat = 8
    public static let radiusIcon: CGFloat = 6
    /// Edit box width cap (bubbles size relative to the column: 88% / 70%).
    public static let bubbleMaxWidth: CGFloat = 620
    public static let transcriptMaxWidth: CGFloat = 900

    /// `msg-in`: 180 ms, cubic-bezier(.22,1,.36,1).
    public static let appear = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    /// `panel-in`: 240 ms, same curve.
    public static let panelIn = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    /// Tailwind's default transition: 150 ms cubic-bezier(.4,0,.2,1).
    public static let quick = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)
}

/// A row that lights up under the pointer, the web's `hover:bg-hover`.
struct HoverHighlight: ViewModifier {
    var selected: Bool
    var radius: CGFloat = Theme.smallRadius
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear)
            )
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

extension View {
    func hoverHighlight(selected: Bool = false, radius: CGFloat = Theme.smallRadius) -> some View {
        modifier(HoverHighlight(selected: selected, radius: radius))
    }
}

/// A flat pill button in the panel style.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .medium : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Theme.accentInk : Theme.ink)
            .background(
                Capsule().fill(prominent ? Theme.accent : configuration.isPressed ? Theme.raisedHover : Theme.raised)
            )
            .brightness(prominent && configuration.isPressed ? 0.1 : 0)
    }
}

/// A borderless icon button that highlights on hover.
public struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var iconSize: CGFloat = 16
    var active = false

    public init(size: CGFloat = 28, iconSize: CGFloat = 16, active: Bool = false) {
        self.size = size
        self.iconSize = iconSize
        self.active = active
    }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, iconSize: iconSize, active: active)
    }

    /// `rounded-md p-1.5`: ink-secondary, hover `raised` + ink, active accent.
    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        let iconSize: CGFloat
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(active ? Theme.accent : hovering ? Theme.ink : Theme.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.radiusIcon, style: .continuous)
                    .fill(configuration.isPressed ? Theme.raisedHover : hovering ? Theme.raised : .clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusIcon))
                .onHover { hovering = $0 }
                .animation(Theme.quick, value: hovering)
        }
    }
}

/// Outlined capsule chip of the header (`+ Task`, usage, folder, Stop):
/// border `hairline/40`, optional `raised/60` fill, 10/4 padding.
public struct ChipButtonStyle: ButtonStyle {
    var filled = false
    var size: CGFloat = 12.5
    /// Solid fill with white ink, brighter on hover (Stop is `Theme.danger`).
    var tint: Color? = nil

    public init(filled: Bool = false, size: CGFloat = 12.5, tint: Color? = nil) {
        self.filled = filled
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, filled: filled, size: size, tint: tint)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let filled: Bool
        let size: CGFloat
        let tint: Color?
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size, weight: tint == nil ? .regular : .medium))
                .foregroundStyle(tint != nil ? Theme.dangerInk : hovering ? Theme.ink : Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint ?? (hovering ? Theme.raised : filled ? Theme.raised.opacity(0.6) : .clear)))
                .brightness(tint != nil && hovering ? 0.1 : 0)
                .overlay(Capsule().stroke(tint == nil ? Theme.hairline.opacity(0.4) : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.quick, value: hovering)
        }
    }
}
