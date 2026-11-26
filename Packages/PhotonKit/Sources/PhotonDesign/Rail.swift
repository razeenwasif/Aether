import SwiftUI

/// Lays a rotated child out at its rotated size, so vertical rail labels take
/// their real height in a stack (`rotationEffect` alone changes no layout).
public struct Rotated90: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return CGSize(width: size.height, height: size.width)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

/// A label set vertically, reading upward like a book's spine.
public struct SpineText: View {
    let text: String
    let font: Font

    public init(_ text: String, font: Font = .system(size: 11.5, weight: .medium)) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Rotated90 {
            Text(text).font(font).fixedSize().rotationEffect(.degrees(-90))
        }
    }
}

/// A rail button: a vertical label in a 24 pt pill.
public struct RailButton: View {
    public enum Style {
        /// A workspace tab or a toggle: raised when on.
        case tab
        /// The run control: the one bright thing in the chrome.
        case run
        /// Run while something runs, filled to `progress`.
        case running(progress: Double)
        /// A field-like button such as Search.
        case field
    }

    let title: String
    let style: Style
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, style: Style = .tab, isOn: Bool = false, help: String = "", action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isOn = isOn
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SpineText(title, font: .system(size: 11.5, weight: isRun ? .semibold : .medium))
                .padding(.vertical, 9)
                .frame(width: 24)
                .foregroundStyle(foreground)
                .background(background)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help.isEmpty ? title : help)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }

    private var isRun: Bool {
        switch style {
        case .run, .running: true
        default: false
        }
    }

    private var foreground: Color {
        switch style {
        case .run, .running: .obsidian0
        case .field: .ink
        case .tab: isOn ? .inkHi : .ink2
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch style {
        case .run:
            shape.fill(Color.runFill).shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        case .running(let progress):
            shape.fill(Color.runFill)
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Rectangle().fill(Color(hex: 0xC3C8D3))
                            .frame(height: geo.size.height * max(0, min(1, progress)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(shape)
        case .field:
            shape.fill(Color.raise1).overlay(shape.strokeBorder(Color.line2, lineWidth: 1))
        case .tab:
            shape.fill(isOn ? Color.raise2 : (hovering ? Color.white.opacity(0.06) : .clear))
                .overlay(shape.strokeBorder(Color.white.opacity(isOn ? 0.08 : 0), lineWidth: 1))
        }
    }
}
