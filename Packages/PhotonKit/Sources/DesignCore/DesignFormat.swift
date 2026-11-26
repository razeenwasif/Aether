import Foundation

// A design's files as the Design workspace reads them: photon-design's
// `format`. Its writer leaves out what is empty, so every field here reads
// as its default when absent, as the Rust types do.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

/// A number, or a word: a token's name, `hug`, `fill`, a CSS value.
public enum DesignVal: Codable, Hashable, Sendable, CustomStringConvertible {
    case num(Double)
    case text(String)

    public static let hug = DesignVal.text("hug")
    public static let fill = DesignVal.text("fill")

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .num(n) } else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .num(n): try c.encode(n)
        case let .text(t): try c.encode(t)
        }
    }

    /// As the core's ops take it.
    public var json: Any {
        switch self {
        case let .num(n): n
        case let .text(t): t
        }
    }

    public var number: Double? { if case let .num(n) = self { n } else { nil } }
    public var word: String? { if case let .text(t) = self { t } else { nil } }
    public var isToken: Bool { word?.hasPrefix("--") == true }

    public var description: String {
        switch self {
        case let .num(n): n.formatted(.number.precision(.fractionLength(0...2)))
        case let .text(t): t
        }
    }
}

/// What a layer is.
public enum DesignKind: String, Codable, Sendable, CaseIterable {
    /// A box that lays out its children in a row or a column.
    case frame
    /// A run of text, wrapped to the width it is given.
    case text
    /// A plain shape.
    case rect
    /// A picture from the design's `images/`.
    case image
    /// A component placed on a page.
    case instance

    public var title: String {
        switch self {
        case .frame: "Frame"
        case .text: "Text"
        case .rect: "Shape"
        case .image: "Image"
        case .instance: "Instance"
        }
    }
}

/// A width a page is drawn at.
public struct DesignBreakpoint: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var width: Double

    enum CodingKeys: String, CodingKey { case id, name, width }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        width = try c.value(.width, 0)
    }
}

/// How a frame lays out its children.
public struct DesignFlex: Decodable, Hashable, Sendable {
    public var direction: String?
    public var gap: DesignVal?
    public var padH: DesignVal?
    public var padV: DesignVal?
    public var align: String?
    public var justify: String?
    public var wrap: Bool?

    public init() {}
    public var isRow: Bool { direction == "row" }

    /// `other`'s fields where it says them.
    func over(_ other: DesignFlex) -> DesignFlex {
        var out = self
        if let v = other.direction { out.direction = v }
        if let v = other.gap { out.gap = v }
        if let v = other.padH { out.padH = v }
        if let v = other.padV { out.padV = v }
        if let v = other.align { out.align = v }
        if let v = other.justify { out.justify = v }
        if let v = other.wrap { out.wrap = v }
        return out
    }
}

/// How a layer looks.
public struct DesignStyle: Decodable, Hashable, Sendable {
    public var fill: String?
    public var stroke: String?
    public var radius: DesignVal?
    public var color: String?
    public var font: String?
    public var textAlign: String?
    public var opacity: Double?
    /// How a picture fills its layer: `cover` or `contain`.
    public var fit: String?

    public init() {}

    /// `other`'s fields where it says them.
    func over(_ other: DesignStyle) -> DesignStyle {
        var out = self
        if let v = other.fill { out.fill = v }
        if let v = other.stroke { out.stroke = v }
        if let v = other.radius { out.radius = v }
        if let v = other.color { out.color = v }
        if let v = other.font { out.font = v }
        if let v = other.textAlign { out.textAlign = v }
        if let v = other.opacity { out.opacity = v }
        if let v = other.fit { out.fit = v }
        return out
    }
}

/// What a narrower breakpoint says of a layer where it differs; each field
/// unsaid is the wider breakpoint's (photon-design's `Override`).
public struct DesignOverride: Decodable, Hashable, Sendable {
    public var w: DesignVal?
    public var h: DesignVal?
    public var minW: Double?
    public var hidden: Bool?
    public var layout: DesignFlex
    public var style: DesignStyle

    enum CodingKeys: String, CodingKey { case w, h, minW, hidden, layout, style }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = try c.decodeIfPresent(DesignVal.self, forKey: .w)
        h = try c.decodeIfPresent(DesignVal.self, forKey: .h)
        minW = try c.decodeIfPresent(Double.self, forKey: .minW)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        layout = try c.value(.layout, DesignFlex())
        style = try c.value(.style, DesignStyle())
    }

    /// Whether it says the field at `keys`: `["w"]`, `["layout", "gap"]`.
    public func says(_ keys: [String]) -> Bool {
        switch keys {
        case ["w"]: w != nil
        case ["h"]: h != nil
        case ["minW"]: minW != nil
        case ["hidden"]: hidden != nil
        case let k where k.count == 2 && k[0] == "layout":
            Mirror(reflecting: layout).children.contains { $0.label == k[1] && !Self.isNil($0.value) }
        case let k where k.count == 2 && k[0] == "style":
            Mirror(reflecting: style).children.contains { $0.label == k[1] && !Self.isNil($0.value) }
        default: false
        }
    }

    private static func isNil(_ value: Any) -> Bool {
        if case Optional<Any>.none = value { true } else { false }
    }
}

/// One layer of a page.
public struct DesignLayer: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: DesignKind
    public var name: String
    public var tag: String
    public var text: String
    public var children: [String]
    /// An image's file in the design's folder: `images/key-art.png`.
    public var src: String
    /// Not drawn, and taking no room.
    public var hidden: Bool
    public var w: DesignVal?
    public var h: DesignVal?
    public var minW: Double?
    public var layout: DesignFlex
    public var style: DesignStyle
    /// What a narrower breakpoint says otherwise, by its id.
    public var at: [String: DesignOverride]
    /// In a component: what an option of a prop changes, by `prop=option`.
    public var when: [String: DesignOverride]
    /// An instance's component, by id; on the layers it's expanded into,
    /// the component they came from.
    public var component: String
    /// An instance's option of each prop it doesn't leave at the default.
    public var props: [String: String]
    /// An instance's words for its component's text layers, by their id.
    public var texts: [String: String]

    enum CodingKeys: String, CodingKey { case id, kind, name, tag, text, children, src, hidden, w, h, minW, layout, style, at, when, component, props, texts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        kind = try c.value(.kind, .frame)
        name = try c.value(.name, "")
        tag = try c.value(.tag, "")
        text = try c.value(.text, "")
        children = try c.value(.children, [])
        src = try c.value(.src, "")
        hidden = try c.value(.hidden, false)
        w = try c.decodeIfPresent(DesignVal.self, forKey: .w)
        h = try c.decodeIfPresent(DesignVal.self, forKey: .h)
        minW = try c.decodeIfPresent(Double.self, forKey: .minW)
        layout = try c.value(.layout, DesignFlex())
        style = try c.value(.style, DesignStyle())
        at = try c.value(.at, [:])
        when = try c.value(.when, [:])
        component = try c.value(.component, "")
        props = try c.value(.props, [:])
        texts = try c.value(.texts, [:])
    }

    /// The instance on a page a layer drawn there belongs to: itself, or for
    /// `wishlist.label`, `wishlist`.
    public static func owner(of id: String) -> String {
        id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? id
    }

    /// `o` laid over it.
    func over(_ o: DesignOverride) -> DesignLayer {
        var out = self
        if let v = o.w { out.w = v }
        if let v = o.h { out.h = v }
        if let v = o.minW { out.minW = v }
        if let v = o.hidden { out.hidden = v }
        out.layout = layout.over(o.layout)
        out.style = style.over(o.style)
        return out
    }

    /// What the layer tree calls it.
    public var label: String { name.isEmpty ? id : name }

    /// Its width as said, or the kind's: `fill` for a frame or a shape,
    /// `hug` for text (photon-design's `html::width`).
    public var width: DesignVal { w ?? (kind == .text ? .hug : .fill) }
    /// Its height as said, or `hug` (100 points for a shape).
    public var height: DesignVal { h ?? (kind == .rect ? .num(100) : .hug) }
}

/// A page: the widths it is drawn at, and its layers.
public struct DesignPage: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var breakpoints: [DesignBreakpoint]
    public var root: String
    public var layers: [DesignLayer]

    enum CodingKeys: String, CodingKey { case id, name, breakpoints, root, layers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        breakpoints = try c.value(.breakpoints, [])
        root = try c.value(.root, "")
        layers = try c.value(.layers, [])
    }

    init(id: String, name: String, breakpoints: [DesignBreakpoint], root: String, layers: [DesignLayer]) {
        self.id = id
        self.name = name
        self.breakpoints = breakpoints
        self.root = root
        self.layers = layers
    }

    public func layer(_ id: String) -> DesignLayer? {
        layers.first { $0.id == id }
    }

    /// The breakpoints widest first: the page's own, then each that says
    /// otherwise.
    public var widestFirst: [DesignBreakpoint] { breakpoints.sorted { $0.width > $1.width } }

    /// The same layers at `points`' widths: a component's, to see it at the
    /// breakpoints of a page that places it.
    public func with(breakpoints points: [DesignBreakpoint]) -> DesignPage {
        var page = self
        page.breakpoints = points
        return page
    }

    /// The page as it is at breakpoint `id`: what it and every wider
    /// breakpoint say laid over each layer, as the media queries cascade
    /// (photon-design's `Page::at`).
    public func at(_ id: String?) -> DesignPage {
        let points = widestFirst
        guard let id, let place = points.firstIndex(where: { $0.id == id }), place > 0 else { return self }
        let wider = points[1...place].map(\.id)
        var page = self
        page.layers = layers.map { layer in
            wider.reduce(layer) { layer, point in layer.at[point].map(layer.over) ?? layer }
        }
        return page
    }

    /// The frame `id` is in.
    public func parent(of id: String) -> DesignLayer? {
        layers.first { $0.children.contains(id) }
    }

    /// The layers in the tree's order with their depth, as the layer panel
    /// lists them; a loop is walked once.
    public func tree() -> [(layer: DesignLayer, depth: Int)] {
        var out: [(DesignLayer, Int)] = []
        var seen = Set<String>()
        func walk(_ id: String, _ depth: Int) {
            guard seen.insert(id).inserted, let layer = layer(id) else { return }
            out.append((layer, depth))
            for child in layer.children { walk(child, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /// `id` and every layer inside it.
    public func subtree(_ id: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func walk(_ id: String) {
            guard seen.insert(id).inserted, let layer = layer(id) else { return }
            out.append(id)
            layer.children.forEach(walk)
        }
        walk(id)
        return out
    }

    /// The frames `id` is inside, nearest first.
    public func ancestors(of id: String) -> [DesignLayer] {
        var out: [DesignLayer] = []
        var at = id
        while let up = parent(of: at), !out.contains(where: { $0.id == up.id }) {
            out.append(up)
            at = up.id
        }
        return out
    }
}

/// One of a component's props: `variant`, and its options, the first the
/// default.
public struct DesignProp: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var options: [String]

    public var id: String { name }
    public var defaultOption: String { options.first ?? "" }
}

/// A component: a tree of layers placed on pages as instances, and its
/// props (photon-design's `Component`).
public struct DesignComponent: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var props: [DesignProp]
    /// Which of `allStates` it has a look for.
    public var states: [String]
    public var root: String
    public var layers: [DesignLayer]

    /// The states a component can have a look for, in the CSS's order:
    /// hover, focus and pressed are how someone uses the page; a page can
    /// make one disabled.
    public static let allStates = ["hover", "focus", "pressed", "disabled"]

    enum CodingKeys: String, CodingKey { case id, name, props, states, root, layers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        props = try c.value(.props, [])
        states = try c.value(.states, [])
        root = try c.value(.root, "")
        layers = try c.value(.layers, [])
    }

    /// The component as a page, its layers as `option` (`variant=secondary`)
    /// changes them, or as written.
    public func asPage(_ option: String? = nil) -> DesignPage {
        let layers = option.map { key in self.layers.map { layer in layer.when[key].map(layer.over) ?? layer } } ?? self.layers
        return DesignPage(id: id, name: name, breakpoints: [], root: root, layers: layers)
    }

    /// Each option there is to show, then each state: `prop=option` or
    /// `state=hover`, with a name for it.
    public var options: [(key: String, name: String)] {
        let title = { (word: String) in word.prefix(1).uppercased() + word.dropFirst() }
        return props.flatMap { prop in prop.options.map { ("\(prop.name)=\($0)", title($0)) } }
            + Self.allStates.filter(states.contains).map { ("state=\($0)", title($0)) }
    }

    /// The text layers an instance can give words to.
    public var textLayers: [DesignLayer] { asPage().tree().map(\.layer).filter { $0.kind == .text } }
}

/// One custom property of the theme, and where it is (proton-design's
/// `Token`).
public struct DesignToken: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var value: String
    /// The blocks it is declared in: `:root`, or a dark palette's media
    /// query and selector.
    public var scope: String
    public var line: Int

    public var id: String { "\(scope)|\(name)" }
}

/// What the workspace reads of an open design: everything but the layers.
public struct DesignView: Decodable, Sendable {
    public struct Info: Decodable, Sendable {
        public var name: String
        public var pages: [String]
        /// The folder of HTML and CSS it's kept in step with, as
        /// `design.json` says it; empty for none.
        public var sync: String
        /// What that folder is written as: `react`, `tailwind`, or empty for
        /// HTML.
        public var syncAs: String
        enum CodingKeys: String, CodingKey { case name, pages, sync, syncAs }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            pages = try c.value(.pages, [])
            sync = try c.value(.sync, "")
            syncAs = try c.value(.syncAs, "")
        }
    }

    public struct PageRow: Decodable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var dirty: Bool
        public var canUndo: Bool
        public var canRedo: Bool
    }

    public struct ComponentRow: Decodable, Sendable, Identifiable {
        public struct Use: Decodable, Sendable, Hashable {
            public var page: String
            public var layer: String
        }
        public var id: String
        public var name: String
        public var dirty: Bool
        public var uses: [Use]
    }

    public struct Theme: Decodable, Sendable {
        public var exists: Bool
        public var tokens: [DesignToken]
        public var dirty: Bool
    }

    public var path: String
    public var design: Info
    public var pages: [PageRow]
    public var components: [ComponentRow]
    public var theme: Theme
    public var unsaved: [String]
    public var problems: [String]
}

/// A design in a folder, as the home page lists it.
public struct DesignFound: Decodable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var pages: Int

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// What reading a file of the sync folder back did: the document it
/// changed, whether it did, and what it couldn't take.
public struct DesignSyncRead: Decodable, Sendable, Equatable {
    public var target: String
    public var changed: Bool
    public var notes: [String]
}

/// A layer's code: its elements and the rules that style them.
public struct DesignCode: Decodable, Sendable, Equatable {
    public var html: String
    public var css: String
}
