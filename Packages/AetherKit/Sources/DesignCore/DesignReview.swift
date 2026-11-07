import AppKit
import Foundation

/// How much a finding matters.
public enum DesignFindingLevel: Int, Comparable, Sendable {
    /// Someone can't read or use it, or it spills out of its frame.
    case problem = 0
    /// Worse to use than it needs to be.
    case warning = 1
    /// Fine to use; worth tidying.
    case note = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One thing the review found: what, where, and when it shows.
public struct DesignFinding: Identifiable, Hashable, Sendable {
    public var level: DesignFindingLevel
    /// The check that found it: `overflow`, `contrast`, `touch`…
    public var kind: String
    /// The layer on the page: an instance's, for a layer drawn inside one.
    public var layer: String
    /// The breakpoint it shows at; nil, wherever the page is drawn.
    public var breakpoint: String?
    /// The scheme it shows in; nil, as written.
    public var scheme: String?
    /// What's wrong, in a sentence.
    public var said: String

    public var id: String { "\(kind)|\(layer)|\(breakpoint ?? "")|\(scheme ?? "")|\(said)" }
}

/// Pagepilot: a page's layout reviewed, not generated. It lays the page out
/// at each breakpoint in each scheme, as the artboards draw it, and says what
/// would go wrong — by measuring, so the same page always gets the same
/// answer, and it never changes the design.
public enum DesignReview {
    /// WCAG's AA for text, and for large text: 24 pt, or 18.66 pt and bold.
    static let enough: CGFloat = 4.5
    static let enoughLarge: CGFloat = 3
    /// Below this width, a breakpoint is for fingers.
    static let forFingers: Double = 768
    /// The smallest a finger's target should be, as Apple's guidelines say.
    static let target: CGFloat = 44
    /// The smallest text worth setting.
    static let smallest: CGFloat = 12

    /// Everything wrong with `page` (with its instances expanded), most
    /// serious first.
    public static func review(_ page: DesignPage, tokens: [DesignToken], measure: DesignMeasuring = DesignText(), images: @escaping (String) -> CGSize? = { _ in nil }) -> [DesignFinding] {
        var found: [DesignFinding] = []
        let points = page.widestFirst
        let schemes: [String?] = [nil] + DesignResolver.schemes(in: tokens).map(Optional.some)
        let plain = DesignResolver(tokens: tokens)
        for point in points {
            let here = page.at(point.id)
            let laid = DesignLayout.lay(here, width: point.width, resolver: plain, measure: measure, images: images)
            overflow(here, laid, point, resolver: plain, measure: measure, into: &found)
            touch(here, laid, point, into: &found)
            small(here, laid, point, resolver: plain, into: &found)
            for scheme in schemes {
                contrast(here, laid, point, scheme: scheme, resolver: DesignResolver(tokens: tokens, scheme: scheme), into: &found)
            }
        }
        headings(page, into: &found)
        pictures(page, into: &found)
        rawValues(page, tokens: tokens, into: &found)
        var seen = Set<String>()
        return merged(found, points: Set(points.map(\.id))).filter { seen.insert($0.id).inserted }.enumerated()
            .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element)
    }

    /// A contrast that's the same at every breakpoint said once, for the
    /// page, not once a breakpoint.
    private static func merged(_ found: [DesignFinding], points: Set<String>) -> [DesignFinding] {
        var out: [DesignFinding] = []
        var byPlace: [String: [DesignFinding]] = [:]
        for finding in found {
            byPlace["\(finding.kind)|\(finding.layer)|\(finding.scheme ?? "")", default: []].append(finding)
        }
        var taken = Set<String>()
        for finding in found {
            let key = "\(finding.kind)|\(finding.layer)|\(finding.scheme ?? "")"
            guard let same = byPlace[key], finding.kind == "contrast", Set(same.compactMap(\.breakpoint)) == points, Set(same.map(\.said)).count == 1 else {
                out.append(finding)
                continue
            }
            if taken.insert(key).inserted {
                var one = finding
                one.breakpoint = nil
                out.append(one)
            }
        }
        return out
    }

    /// What a sentence calls a layer: its name, and when another layer on
    /// the page shares it, the frame it's in — three cards each have a Body.
    private static func name(_ layer: DesignLayer, _ page: DesignPage) -> String {
        guard page.layers.filter({ $0.label == layer.label }).count > 1, let frame = page.parent(of: layer.id) else { return layer.label }
        return "\(layer.label) (\(frame.label))"
    }

    /// A number as it reads in a sentence.
    private static func pts(_ value: CGFloat) -> String { "\(Int(value.rounded())) pt" }

    // MARK: Overflow

    private static func overflow(_ page: DesignPage, _ laid: DesignLaidOut, _ point: DesignBreakpoint, resolver: DesignResolver, measure: DesignMeasuring, into found: inout [DesignFinding]) {
        for id in laid.order {
            guard let frame = laid.frames[id], let layer = page.layer(id) else { continue }
            let owner = DesignLayer.owner(of: id)
            // Past its frame, to either side; past the bottom only of a frame
            // whose height is set, since one that hugs grows.
            if let parent = page.parent(of: id), let outer = laid.frames[parent.id] {
                let over = max(frame.maxX - outer.maxX, outer.minX - frame.minX, parent.height.number != nil ? frame.maxY - outer.maxY : 0)
                if over > 0.5 {
                    found.append(DesignFinding(level: .problem, kind: "overflow", layer: owner, breakpoint: point.id, said: "\(name(layer, page)) runs \(pts(over)) past \(name(parent, page)) at \(point.name)."))
                }
            } else if frame.maxX - laid.width > 0.5 {
                found.append(DesignFinding(level: .problem, kind: "overflow", layer: owner, breakpoint: point.id, said: "\(name(layer, page)) runs \(pts(frame.maxX - laid.width)) off the page at \(point.name)."))
            }
            // Words that need more room than a set height gives them.
            if layer.kind == .text, layer.height.number != nil {
                let needs = measure.size(of: layer.text, font: resolver.font(layer.style.font), width: max(1, frame.width)).height
                if needs - frame.height > 0.5 {
                    found.append(DesignFinding(level: .problem, kind: "overflow", layer: owner, breakpoint: point.id, said: "\(name(layer, page))'s words need \(pts(needs)) at \(point.name), and it's set to \(pts(frame.height))."))
                }
            }
        }
    }

    // MARK: Touch

    private static func interactive(_ layer: DesignLayer) -> Bool {
        ["a", "button"].contains(layer.tag.lowercased())
    }

    private static func touch(_ page: DesignPage, _ laid: DesignLaidOut, _ point: DesignBreakpoint, into found: inout [DesignFinding]) {
        guard point.width < forFingers else { return }
        for id in laid.order {
            guard let layer = page.layer(id), interactive(layer), let frame = laid.frames[id] else { continue }
            // A target's size is its own; one inside a target is that target.
            if page.ancestors(of: id).contains(where: interactive) { continue }
            let short = frame.height < target - 0.5, narrow = frame.width < target - 0.5
            guard short || narrow else { continue }
            let size = short && narrow ? "\(pts(frame.width)) by \(pts(frame.height))" : short ? "\(pts(frame.height)) tall" : "\(pts(frame.width)) wide"
            found.append(DesignFinding(level: .warning, kind: "touch", layer: DesignLayer.owner(of: id), breakpoint: point.id, said: "\(name(layer, page)) is \(size) at \(point.name); a finger needs \(pts(target))."))
        }
    }

    // MARK: Small text

    private static func small(_ page: DesignPage, _ laid: DesignLaidOut, _ point: DesignBreakpoint, resolver: DesignResolver, into found: inout [DesignFinding]) {
        for id in laid.order {
            guard let layer = page.layer(id), layer.kind == .text else { continue }
            let size = resolver.font(layer.style.font).size
            if size < smallest - 0.01 {
                found.append(DesignFinding(level: .warning, kind: "small", layer: DesignLayer.owner(of: id), breakpoint: point.id, said: "\(name(layer, page)) is set at \(pts(size)) at \(point.name); under \(pts(smallest)) is hard to read."))
            }
        }
    }

    // MARK: Contrast

    /// `sRGB` components, opaque or not.
    private static func parts(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// `top` over an opaque `under`.
    private static func over(_ top: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat), _ under: (r: CGFloat, g: CGFloat, b: CGFloat)) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (top.r * top.a + under.r * (1 - top.a), top.g * top.a + under.g * (1 - top.a), top.b * top.a + under.b * (1 - top.a))
    }

    /// WCAG's relative luminance.
    private static func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func line(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * line(c.r) + 0.7152 * line(c.g) + 0.0722 * line(c.b)
    }

    /// WCAG's contrast ratio between two opaque colours.
    public static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (parts(a), parts(b))
        return ratio((x.r, x.g, x.b), (y.r, y.g, y.b))
    }

    private static func ratio(_ a: (r: CGFloat, g: CGFloat, b: CGFloat), _ b: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func contrast(_ page: DesignPage, _ laid: DesignLaidOut, _ point: DesignBreakpoint, scheme: String?, resolver: DesignResolver, into found: inout [DesignFinding]) {
        for id in laid.order {
            guard let layer = page.layer(id), layer.kind == .text, !layer.text.isEmpty else { continue }
            let frames = page.ancestors(of: id)
            // A disabled control is excused, as WCAG excuses it.
            if frames.contains(where: { $0.props["state"] == "disabled" }) { continue }
            // What's behind it: its frames' fills, nearest first, down to the
            // first opaque one, or a browser's white page.
            var behind: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)
            var fills: [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = []
            for frame in frames {
                guard let fill = resolver.color(frame.style.fill) else { continue }
                let p = parts(fill)
                fills.append(p)
                if p.a >= 0.999 { break }
            }
            for fill in fills.reversed() { behind = over(fill, behind) }
            let colour = resolver.color(layer.style.color) ?? .black
            // Faded with the layers around it, the words are fainter.
            let fade = ([layer] + frames).reduce(CGFloat(1)) { $0 * CGFloat($1.style.opacity ?? 1) }
            var words = parts(colour)
            words.a *= fade
            let font = resolver.font(layer.style.font)
            let large = font.size >= 24 || (font.size >= 18.66 && font.weight >= 700)
            let need = large ? enoughLarge : enough
            let have = ratio(over(words, behind), behind)
            if have < need - 0.005 {
                let scene = scheme.map { " in \($0)" } ?? ""
                let value = String(format: "%.1f", have)
                found.append(DesignFinding(level: .problem, kind: "contrast", layer: DesignLayer.owner(of: id), breakpoint: point.id, scheme: scheme, said: "\(name(layer, page))'s words are \(value):1 against what's behind them\(scene); \(large ? "large text" : "text") needs \(String(format: "%g", need)):1."))
            }
        }
    }

    // MARK: Headings

    private static func headings(_ page: DesignPage, into found: inout [DesignFinding]) {
        var levels: [(layer: DesignLayer, level: Int)] = []
        for row in page.tree() {
            let tag = row.layer.tag.lowercased()
            if tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) {
                levels.append((row.layer, level))
            }
        }
        if !levels.contains(where: { $0.level == 1 }) {
            found.append(DesignFinding(level: .warning, kind: "headings", layer: page.root, said: "\(page.name) has no h1: nothing says what the page is."))
        }
        for extra in levels.filter({ $0.level == 1 }).dropFirst() {
            found.append(DesignFinding(level: .warning, kind: "headings", layer: DesignLayer.owner(of: extra.layer.id), said: "\(name(extra.layer, page)) is a second h1 on \(page.name)."))
        }
        var last = 0
        for heading in levels {
            if last > 0, heading.level > last + 1 {
                found.append(DesignFinding(level: .warning, kind: "headings", layer: DesignLayer.owner(of: heading.layer.id), said: "\(name(heading.layer, page)) is an h\(heading.level) after an h\(last): a level is skipped for someone reading by headings."))
            }
            last = heading.level
        }
    }

    // MARK: Pictures

    private static func pictures(_ page: DesignPage, into found: inout [DesignFinding]) {
        for row in page.tree() where row.layer.kind == .image && row.layer.text.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(DesignFinding(level: .problem, kind: "picture", layer: DesignLayer.owner(of: row.layer.id), said: "\(name(row.layer, page)) doesn't say what it shows, for someone who can't see it."))
        }
    }

    // MARK: Raw values

    private static func rawValues(_ page: DesignPage, tokens: [DesignToken], into found: inout [DesignFinding]) {
        let root = tokens.filter { $0.scope == ":root" }
        for row in page.tree() {
            let style = row.layer.style
            for value in [style.fill, style.stroke, style.color].compactMap({ $0 }) where !value.hasPrefix("--") {
                guard let same = DesignResolver.color(css: value), same.alphaComponent > 0,
                      let token = root.first(where: { DesignResolver.color(css: $0.value).map { DesignResolver.hex($0) } == DesignResolver.hex(same) }) else { continue }
                found.append(DesignFinding(level: .note, kind: "raw", layer: DesignLayer.owner(of: row.layer.id), said: "\(name(row.layer, page)) says \(value) where \(token.name) says the same: with the token, it follows the palette."))
            }
        }
    }
}
