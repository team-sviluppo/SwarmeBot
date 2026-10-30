import SwarmeKit
import SwiftUI

/// Keep the compact action row, with an explicit way to reveal controls beyond its edge.
struct ComposerActions<Content: View>: View {
    @AppStorage("composer.actions.expanded", store: AppPaths.defaults) private var expanded = false
    @State private var naturalWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @ViewBuilder var content: Content

    private var overflows: Bool { availableWidth > 0 && naturalWidth > availableWidth + 1 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                let layout = expanded
                    ? AnyLayout(ComposerActionsLayout(width: max(1, availableWidth - 36)))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout { content }
                    .background {
                        if !expanded {
                            GeometryReader { geometry in
                                Color.clear.preference(key: ActionContentWidth.self, value: geometry.size.width)
                            }
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if overflows || expanded {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(IconButtonStyle(size: 28, iconSize: 12, active: expanded))
                .help(expanded ? tr("Riduci le opzioni") : tr("Mostra tutte le opzioni"))
                .accessibilityLabel(expanded ? tr("Riduci le opzioni") : tr("Mostra tutte le opzioni"))
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ActionAvailableWidth.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(ActionContentWidth.self) { if $0 > 0 { naturalWidth = $0 } }
        .onPreferenceChange(ActionAvailableWidth.self) { availableWidth = $0 }
        .padding(.leading, 6)
    }
}

private struct ActionContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ActionAvailableWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A horizontal scroll view proposes no width. Supply its viewport explicitly to wrap rows.
/// An unusually wide individual control can still be scrolled instead of being clipped.
struct ComposerActionsLayout: Layout {
    var width: CGFloat

    static func frames(sizes: [CGSize], width: CGFloat, spacing: CGFloat = 8) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return sizes.map { size in
            guard size.width > 0, size.height > 0 else { return CGRect(origin: CGPoint(x: x, y: y), size: .zero) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = Self.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width)
        return CGSize(width: max(width, frames.map(\.maxX).max() ?? 0), height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
