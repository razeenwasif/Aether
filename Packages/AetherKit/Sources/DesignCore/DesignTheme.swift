import AppKit
import Foundation

/// What a token's value is, as the inspector offers it.
public enum DesignTokenKind: Sendable {
    case color, length, font, other
}

/// A font as CSS's `font` shorthand says it: `600 15px/1 system-ui`.
public struct DesignFont: Hashable, Sendable {
    public var size: CGFloat = 16
    /// CSS's weight, 100 to 900.
    public var weight: Int = 400
    public var italic = false
    /// The line's height in points, when said.
    public var lineHeight: CGFloat?
    /// The first family named, unquoted.
    public var family = "system-ui"

    public init() {}

    /// `[italic] [weight] size[/line-height] family, …` — the shorthand's
    /// parts a theme uses. Nil when there's no size, which every `font`
    /// needs.
    public init?(css: String) {
        var words = Self.split(css)
        var size: CGFloat?
        var at = 0
        while at < words.count, size == nil {
            let word = words[at].lowercased()
            if word == "italic" || word == "oblique" {
                italic = true
            } else if word == "bold" {
                weight = 700
            } else if word == "normal" {
                // The style's or the weight's default; either way nothing.
            } else if let n = Int(word), (1...1000).contains(n) {
                weight = n
            } else {
                let parts = word.split(separator: "/", maxSplits: 1).map(String.init)
                guard let points = DesignResolver.points(parts[0]) else { return nil }
                size = points
                if parts.count > 1 {
                    let lh = parts[1]
                    if let n = Double(lh) { lineHeight = points * n }
                    else if lh.hasSuffix("%"), let n = Double(lh.dropLast()) { lineHeight = points * n / 100 }
                    else { lineHeight = DesignResolver.points(lh) }
                }
            }
            at += 1
        }
        guard let size else { return nil }
        self.size = size
        words.removeFirst(at)
        let families = words.joined(separator: " ").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        family = families.first.flatMap { $0.isEmpty ? nil : $0 } ?? "system-ui"
    }

    /// Words, a quoted family kept whole.
    private static func split(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        var quote: Character?
        for c in text {
            if let q = quote {
                word.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                word.append(c)
            } else if c == " " || c == "\t" {
                if !word.isEmpty { out.append(word); word = "" }
            } else {
                word.append(c)
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// The font this draws with: the family when the Mac has it, else the
    /// system's at the same weight; `serif` and `monospace` as the system's
    /// own.
    public var nsFont: NSFont {
        let w: NSFont.Weight = switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
        let generic = family.lowercased()
        var font: NSFont
        switch generic {
        case "monospace", "ui-monospace":
            font = .monospacedSystemFont(ofSize: size, weight: w)
        case "serif", "ui-serif":
            let base = NSFont.systemFont(ofSize: size, weight: w)
            font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case "system-ui", "sans-serif", "-apple-system", "blinkmacsystemfont", "ui-sans-serif", "inherit":
            font = .systemFont(ofSize: size, weight: w)
        default:
            let named = NSFontManager.shared.font(withFamily: family, traits: [], weight: Self.managerWeight(weight), size: size)
            font = named ?? .systemFont(ofSize: size, weight: w)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// NSFontManager's 0–15 weight for CSS's 100–900.
    private static func managerWeight(_ css: Int) -> Int {
        max(1, min(14, Int((Double(css) / 100 * 1.5).rounded()) + 1))
    }
}

/// A design's tokens, resolved: a layer says `--color-lantern-500` and this
/// says what colour that is now. `:root`'s tokens are the palette drawn;
/// a dark palette in a media query is listed by the Tokens tab but not yet
/// drawn.
public struct DesignResolver: Sendable {
    private var values: [String: String] = [:]

    public init(tokens: [DesignToken]) {
        for token in tokens where token.scope == ":root" && values[token.name] == nil {
            values[token.name] = token.value
        }
        // Tokens declared only elsewhere still resolve, to something.
        for token in tokens where values[token.name] == nil {
            values[token.name] = token.value
        }
    }

    public func has(_ token: String) -> Bool { values[token] != nil }

    /// A word as CSS would read it: a token's value, its `var()`s followed,
    /// or the word itself.
    public func resolve(_ word: String) -> String? {
        var text = word.trimmingCharacters(in: .whitespaces)
        for _ in 0..<8 {
            if text.hasPrefix("--") {
                guard let next = values[text] else { return nil }
                text = next
            } else if text.hasPrefix("var("), text.hasSuffix(")") {
                let inner = text.dropFirst(4).dropLast()
                let parts = inner.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if let found = values[parts[0]] { text = found } else if parts.count > 1 { text = parts[1] } else { return nil }
            } else {
                return text
            }
        }
        return nil
    }

    public func color(_ word: String?) -> NSColor? {
        word.flatMap(resolve).flatMap(Self.color(css:))
    }

    public func length(_ val: DesignVal?) -> CGFloat? {
        switch val {
        case let .num(n)?: n
        case let .text(word)?: resolve(word).flatMap(Self.points)
        case nil: nil
        }
    }

    public func font(_ word: String?) -> DesignFont {
        word.flatMap(resolve).flatMap(DesignFont.init(css:)) ?? DesignFont()
    }

    /// What a token holds, for offering it where it fits.
    public func kind(of token: DesignToken) -> DesignTokenKind {
        guard let value = resolve(token.name) else { return .other }
        if Self.color(css: value) != nil { return .color }
        if Self.points(value) != nil { return .length }
        if DesignFont(css: value) != nil { return .font }
        return .other
    }

    /// `12px`, `1.5rem`, `0`, or a bare number, in points.
    public static func points(_ text: String) -> CGFloat? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Double(t) { return n }
        if t.hasSuffix("px"), let n = Double(t.dropLast(2)) { return n }
        if t.hasSuffix("rem"), let n = Double(t.dropLast(3)) { return n * 16 }
        if t.hasSuffix("em"), let n = Double(t.dropLast(2)) { return n * 16 }
        if t.hasSuffix("pt"), let n = Double(t.dropLast(2)) { return n * 4 / 3 }
        return nil
    }

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` with commas
    /// or spaces, and a few names. Nil for anything else.
    public static func color(css text: String) -> NSColor? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "transparent": return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        case "white": return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case "black": return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        default: break
        }
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            guard hex.allSatisfy(\.isHexDigit), [3, 4, 6, 8].contains(hex.count) else { return nil }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "ff" }
            guard let n = UInt64(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((n >> 24) & 0xFF) / 255, green: CGFloat((n >> 16) & 0xFF) / 255, blue: CGFloat((n >> 8) & 0xFF) / 255, alpha: CGFloat(n & 0xFF) / 255)
        }
        if (t.hasPrefix("rgb(") || t.hasPrefix("rgba(")), t.hasSuffix(")"), let open = t.firstIndex(of: "(") {
            let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
            let parts = inner.replacingOccurrences(of: "/", with: " ").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ s: String) -> CGFloat? {
                s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : Double(s).map { $0 / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var a: CGFloat = 1
            if parts.count == 4 {
                guard let alpha = parts[3].hasSuffix("%") ? Double(parts[3].dropLast()).map({ $0 / 100 }) : Double(parts[3]) else { return nil }
                a = alpha
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        return nil
    }

    /// A colour as `#rrggbb`, or `#rrggbbaa` when it isn't opaque.
    public static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        let base = "#" + byte(c.redComponent) + byte(c.greenComponent) + byte(c.blueComponent)
        return c.alphaComponent < 0.999 ? base + byte(c.alphaComponent) : base
    }
}
