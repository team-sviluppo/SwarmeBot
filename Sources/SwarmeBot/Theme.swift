// The palette, from `src/styles.css` in the Electron app.
//
// Flat and opaque on purpose: no system vibrancy on the sidebar or the
// inspector. The look is near-black panels with grey bubbles, and a
// translucent sidebar pulls it toward stock macOS and away from that.
import SwiftUI

enum Theme {
    static let app = Color(hex: "#070707")
    static let panel = Color(hex: "#111111")
    static let card = Color(hex: "#262626")
    static let raised = Color(hex: "#2F2F2F")
    static let raisedHover = Color(hex: "#3D3D3D")
    /// Old name for `raisedHover`.
    static var hover: Color { raisedHover }
    static let inset = Color(hex: "#191919")
    static let hairline = Color(hex: "#333333")
    static let ink = Color(hex: "#FCFCFC")
    static let secondary = Color(hex: "#FCFCFC").opacity(0.6)
    static let tertiary = Color(hex: "#FCFCFC").opacity(0.42)
    static let accent = Color(hex: "#1084FE")
    /// Bubbles as in Grok Bot: the bot's a step above the window, yours a step above that.
    static let bubbleUser = Color(hex: "#2E2E2E")
    static let bubbleBot = Color(hex: "#1C1C1C")
    static let success = Color(hex: "#38D591")
    static let danger = Color(hex: "#FF5667")
    static let warning = Color(hex: "#FF9800")
    static let accentBorder = Color(hex: "#459FFE")
    static let focus = Color(hex: "#459FFE")
    static let accentText = Color(hex: "#7FC0FF")
    static let accentInk = Color.white
    static let dangerInk = Color.white
    static let scrollbar = Color(hex: "#3D3D3D")

    /// Chat text, matched to Grok Bot: 14 pt regular, ~20 pt line.
    static let bodySize: CGFloat = 14
    static let bodyLineSpacing: CGFloat = 3
    /// Sidebar name and composer chrome.
    static let uiSize: CGFloat = 13
    static let captionSize: CGFloat = 12
    /// `rounded-xl`
    static let radius: CGFloat = 12
    /// `rounded-lg`
    static let smallRadius: CGFloat = 8
    static let radiusCard: CGFloat = 16
    static let radiusBubble: CGFloat = 14
    static let radiusRow: CGFloat = 8
    static let radiusIcon: CGFloat = 6
    /// Edit box width cap (bubbles size relative to the column: 88% / 70%).
    static let bubbleMaxWidth: CGFloat = 620
    static let transcriptMaxWidth: CGFloat = 900

    /// `msg-in`: 180 ms, cubic-bezier(.22,1,.36,1).
    static let appear = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    /// `panel-in`: 240 ms, same curve.
    static let panelIn = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    /// Tailwind's default transition: 150 ms cubic-bezier(.4,0,.2,1).
    static let quick = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)
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
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var iconSize: CGFloat = 16
    var active = false

    func makeBody(configuration: Configuration) -> some View {
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
struct ChipButtonStyle: ButtonStyle {
    var filled = false
    var size: CGFloat = 12.5
    /// Solid fill with white ink, brighter on hover (Stop is `Theme.danger`).
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
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
