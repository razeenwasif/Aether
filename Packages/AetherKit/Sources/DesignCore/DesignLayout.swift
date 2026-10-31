import AppKit
import Foundation

/// How big a run of text is: its widest line unwrapped (`width` nil), or
/// its height wrapped to `width`.
public protocol DesignMeasuring {
    func size(of text: String, font: DesignFont, width: CGFloat?) -> CGSize
}

/// Text as the artboard draws it, measured the same way: AppKit's string
/// drawing, a CSS line height kept as a fixed line.
public struct DesignText: DesignMeasuring {
    public init() {}

    public static func attributed(_ text: String, font: DesignFont, color: NSColor = .white, align: String? = nil) -> NSAttributedString {
        let ns = font.nsFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = switch align {
        case "center": .center
        case "end": .right
        default: .left
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: ns, .foregroundColor: color, .paragraphStyle: paragraph]
        if let line = font.lineHeight {
            paragraph.minimumLineHeight = line
            paragraph.maximumLineHeight = line
            // CSS puts the extra space half above and half below the glyphs;
            // AppKit puts it all above, so the glyphs are lifted by half.
            attributes[.baselineOffset] = (line - (ns.ascender - ns.descender)) / 2
        }
        return NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
    }

    public func size(of text: String, font: DesignFont, width: CGFloat?) -> CGSize {
        let string = Self.attributed(text, font: font)
        let bounds = string.boundingRect(with: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Rounded up, and a point to spare unwrapped, so text set at its own
        // width doesn't wrap its last word.
        return CGSize(width: ceil(bounds.width) + (width == nil ? 1 : 0), height: ceil(bounds.height))
    }
}

/// A page laid out at one width: where each layer is, in the artboard's
/// points, `y` down.
public struct DesignLaidOut: Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var frames: [String: CGRect]
    /// Layers in the order they're drawn: each frame before what's in it.
    public var order: [String]

    /// The innermost layer at `point`.
    public func hit(_ point: CGPoint) -> String? {
        order.last { frames[$0]?.contains(point) == true }
    }
}

/// Flexbox, as aether-design's HTML writes it, so the artboard and a
/// browser agree:
///
/// - A frame is a flex box: a column unless it says row, its children apart
///   by its gap, inside its padding, placed across it by `align` and along it
///   by `justify`.
/// - Down a column, `fill` is as wide as the column, `hug` as wide as the
///   layer's content up to that, and a height of `fill` shares what the
///   column has left when the column's own height is set.
/// - Along a row, `hug` is the content's width, `fill` grows from its
///   narrowest (`minW`, else nothing) to share what's left, and a row that
///   wraps moves what doesn't fit to the next line.
/// - Text is as tall as it wraps to; a picture as tall as its width at its
///   own aspect; a page is as tall as what it holds.
/// - A hidden layer takes no room.
///
/// Lay out `page.at(breakpoint)` to see a breakpoint as it says.
public struct DesignLayout {
    let page: DesignPage
    let resolver: DesignResolver
    let measure: DesignMeasuring
    /// A picture's size in pixels, by its `src`, when it's known.
    let images: (String) -> CGSize?
    private var frames: [String: CGRect] = [:]
    private var order: [String] = []
    private var visiting: Set<String> = []

    public static func lay(_ page: DesignPage, width: CGFloat, resolver: DesignResolver, measure: DesignMeasuring = DesignText(), images: @escaping (String) -> CGSize? = { _ in nil }) -> DesignLaidOut {
        var layout = DesignLayout(page: page, resolver: resolver, measure: measure, images: images)
        guard let root = page.layer(page.root) else { return DesignLaidOut(width: width, height: 0, frames: [:], order: []) }
        let height = layout.place(root, at: .zero, width: width, height: nil, recording: true)
        return DesignLaidOut(width: width, height: height, frames: layout.frames, order: layout.order)
    }

    private init(page: DesignPage, resolver: DesignResolver, measure: DesignMeasuring, images: @escaping (String) -> CGSize?) {
        self.page = page
        self.resolver = resolver
        self.measure = measure
        self.images = images
    }

    private func children(of layer: DesignLayer) -> [DesignLayer] {
        layer.children.compactMap(page.layer).filter { !visiting.contains($0.id) && !$0.hidden }
    }

    private func pads(_ layer: DesignLayer) -> (h: CGFloat, v: CGFloat, gap: CGFloat) {
        (resolver.length(layer.layout.padH) ?? 0, resolver.length(layer.layout.padV) ?? 0, resolver.length(layer.layout.gap) ?? 0)
    }

    /// Its width with nothing wrapped: CSS's max-content.
    private mutating func natural(_ layer: DesignLayer) -> CGFloat {
        if let n = layer.width.number { return n }
        switch layer.kind {
        case .text:
            return measure.size(of: layer.text, font: resolver.font(layer.style.font), width: nil).width
        case .rect:
            return 0
        case .image:
            return images(layer.src)?.width ?? 0
        case .frame:
            visiting.insert(layer.id)
            defer { visiting.remove(layer.id) }
            let (padH, _, gap) = pads(layer)
            let widths = children(of: layer).map { natural($0) }
            let content = layer.layout.isRow ? widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) : widths.max() ?? 0
            return content + padH * 2
        }
    }

    /// Lay `layer` out at `origin`, `width` wide (and `height` tall, when its
    /// frame decides that); its height. `recording` false measures without
    /// keeping where anything went.
    @discardableResult
    private mutating func place(_ layer: DesignLayer, at origin: CGPoint, width: CGFloat, height: CGFloat?, recording: Bool) -> CGFloat {
        if recording { order.append(layer.id) }
        let said = layer.height.number.map { CGFloat($0) }
        var h: CGFloat
        switch layer.kind {
        case .text:
            h = height ?? said ?? measure.size(of: layer.text, font: resolver.font(layer.style.font), width: max(1, width)).height
        case .rect:
            h = height ?? said ?? 0
        case .image:
            // CSS's `height: auto`: the picture's own aspect, or a wide
            // frame's while there's no picture to measure.
            let aspect = images(layer.src).map { $0.width > 0 ? $0.height / $0.width : 0 } ?? 9.0 / 16.0
            h = height ?? said ?? width * aspect
        case .frame:
            visiting.insert(layer.id)
            h = layer.layout.isRow
                ? row(layer, at: origin, width: width, height: height ?? said, recording: recording)
                : column(layer, at: origin, width: width, height: height ?? said, recording: recording)
            visiting.remove(layer.id)
        }
        if recording { frames[layer.id] = CGRect(x: origin.x, y: origin.y, width: width, height: h) }
        return h
    }

    private mutating func column(_ layer: DesignLayer, at origin: CGPoint, width: CGFloat, height: CGFloat?, recording: Bool) -> CGFloat {
        let (padH, padV, gap) = pads(layer)
        let inner = max(0, width - padH * 2)
        let kids = children(of: layer)
        let widths: [CGFloat] = kids.map { kid in
            switch kid.width {
            case let .num(n): min(n, inner)
            case .fill: inner
            default: min(natural(kid), inner)
            }
        }
        // Heights: what's set or hugs first, then `fill` shares the rest of
        // a column whose own height is set.
        var heights: [CGFloat?] = kids.indices.map { i in kids[i].height == .fill && height != nil ? nil : 0 }
        for i in kids.indices where heights[i] != nil {
            heights[i] = place(kids[i], at: .zero, width: widths[i], height: nil, recording: false)
        }
        let gaps = gap * CGFloat(max(0, kids.count - 1))
        let fills = heights.filter { $0 == nil }.count
        if fills > 0, let height {
            let left = max(0, height - padV * 2 - gaps - heights.compactMap { $0 }.reduce(0, +))
            for i in kids.indices where heights[i] == nil { heights[i] = left / CGFloat(fills) }
        }
        let sizes = heights.map { $0 ?? 0 }
        let content = sizes.reduce(0, +) + gaps
        let total = height ?? content + padV * 2
        let (start, step) = Self.spread(free: total - padV * 2 - content, count: kids.count, justify: layer.layout.justify)
        var y = origin.y + padV + start
        for i in kids.indices {
            let x = origin.x + padH + Self.offset(free: inner - widths[i], align: layer.layout.align)
            place(kids[i], at: CGPoint(x: x, y: y), width: widths[i], height: kids[i].height == .fill && height != nil ? sizes[i] : nil, recording: recording)
            y += sizes[i] + gap + step
        }
        return total
    }

    private mutating func row(_ layer: DesignLayer, at origin: CGPoint, width: CGFloat, height: CGFloat?, recording: Bool) -> CGFloat {
        let (padH, padV, gap) = pads(layer)
        let inner = max(0, width - padH * 2)
        let kids = children(of: layer)
        // Each child's starting width: CSS's flex-basis.
        let bases: [CGFloat] = kids.map { kid in
            switch kid.width {
            case let .num(n): n
            case .fill: kid.minW ?? 0
            default: natural(kid)
            }
        }
        // Lines: one, or as many as a wrapping row needs.
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for i in kids.indices {
            let need = (lines[lines.count - 1].isEmpty ? 0 : gap) + bases[i]
            if layer.layout.wrap == true, !lines[lines.count - 1].isEmpty, used + need > inner + 0.5 {
                lines.append([i])
                used = bases[i]
            } else {
                lines[lines.count - 1].append(i)
                used += need
            }
        }
        // Widths: `fill` grows to share what each line has left.
        var widths = bases
        var free: [CGFloat] = []
        for line in lines {
            let left = inner - line.map { bases[$0] }.reduce(0, +) - gap * CGFloat(max(0, line.count - 1))
            let growing = line.filter { kids[$0].width == .fill }
            if !growing.isEmpty, left > 0 {
                for i in growing { widths[i] += left / CGFloat(growing.count) }
                free.append(0)
            } else {
                free.append(max(0, left))
            }
        }
        // Heights: each line as tall as its tallest; a single line as tall
        // as a row whose height is set.
        var heights: [CGFloat] = kids.indices.map { i in
            kids[i].height == .fill ? 0 : place(kids[i], at: .zero, width: widths[i], height: nil, recording: false)
        }
        let rowGaps = gap * CGFloat(max(0, lines.count - 1))
        var lineHeights = lines.map { line in line.map { heights[$0] }.max() ?? 0 }
        if lines.count == 1, let height { lineHeights[0] = max(0, height - padV * 2) }
        for (l, line) in lines.enumerated() {
            for i in line where kids[i].height == .fill { heights[i] = lineHeights[l] }
        }
        let total = height ?? lineHeights.reduce(0, +) + rowGaps + padV * 2
        var y = origin.y + padV
        for (l, line) in lines.enumerated() {
            let (start, step) = Self.spread(free: free[l], count: line.count, justify: layer.layout.justify)
            var x = origin.x + padH + start
            for i in line {
                let dy = Self.offset(free: lineHeights[l] - heights[i], align: layer.layout.align)
                place(kids[i], at: CGPoint(x: x, y: y + dy), width: widths[i], height: kids[i].height == .fill ? heights[i] : nil, recording: recording)
                x += widths[i] + gap + step
            }
            y += lineHeights[l] + gap
        }
        return total
    }

    /// Where the first child starts along a frame, and what's added between
    /// each, for `justify`.
    static func spread(free: CGFloat, count: Int, justify: String?) -> (start: CGFloat, step: CGFloat) {
        let free = max(0, free)
        switch justify {
        case "center": return (free / 2, 0)
        case "end": return (free, 0)
        case "between": return count > 1 ? (0, free / CGFloat(count - 1)) : (0, 0)
        default: return (0, 0)
        }
    }

    /// How far across a frame a child sits, for `align`.
    static func offset(free: CGFloat, align: String?) -> CGFloat {
        switch align {
        case "center": max(0, free) / 2
        case "end": max(0, free)
        default: 0
        }
    }
}
