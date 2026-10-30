import SwiftUI

/// The two elevations that float over the work: panels and HUDs. Both are
/// glass, so the viewport runs edge to edge underneath them.
public enum Elevation {
    case panel
    case floating
}

public extension View {
    /// A floating glass surface at `elevation`.
    func aeGlass(_ elevation: Elevation = .panel, radius: CGFloat? = nil) -> some View {
        modifier(GlassSurface(elevation: elevation, radius: radius))
    }

    /// Centred in the space the side panels leave, by moving rather than by
    /// padding: padding that follows a sliding panel lays the view out again
    /// every frame of the slide (RESEARCH_PLAN.md §7b).
    func centred(between left: CGFloat, and right: CGFloat) -> some View {
        offset(x: (left - right) / 2)
    }

    /// A side panel slid `distance` off its `edge` while shut, and kept in
    /// the tree so opening it only moves it. Inserting an inspector built
    /// and laid it out from nothing: 50 to 200 ms, a dozen frames or more
    /// at 120 Hz (RESEARCH_PLAN.md §7a).
    func sliding(open: Bool, from edge: HorizontalEdge, by distance: CGFloat) -> some View {
        offset(x: open ? 0 : (edge == .leading ? -distance : distance))
            .opacity(open ? 1 : 0)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
    }
}

private struct GlassSurface: ViewModifier {
    let elevation: Elevation
    let radius: CGFloat?

    func body(content: Content) -> some View {
        let r = radius ?? (elevation == .panel ? Radius.panel : Radius.floating)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.obsidian1.opacity(elevation == .panel ? 0.78 : 0.86))
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(elevation == .panel ? 0.06 : 0.08), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // The specular top edge that makes glass read as a sheet: a
                // plain stroke kept to the top. A gradient stroke is drawn
                // on the CPU, and drawn again each frame a panel moves (§7b).
                shape.strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: r) }
            }
            .shadow(color: .black.opacity(elevation == .panel ? 0.45 : 0.6), radius: elevation == .panel ? 20 : 34, y: elevation == .panel ? 12 : 20)
    }
}

/// A section of a panel: a small label, then its rows.
public struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.aeLabel).foregroundStyle(Color.ink2)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}

/// A pill that names a state with a dot of its colour and a word.
public struct StatePill: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// A button that is only a glyph, with hover and pressed fills.
public struct IconButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(_ symbol: String, label: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn ? Color.obsidian0 : Color.ink)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(isOn ? Color.runFill : (hovering ? Color.white.opacity(0.06) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}
