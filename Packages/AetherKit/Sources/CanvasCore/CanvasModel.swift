import Foundation

/// How a canvas is meant to be drawn: a small grid of pixels from a palette,
/// or a large picture of soft brushes over blended layers.
public enum CanvasPreset: String, Codable, Sendable, CaseIterable {
    case pixel, paint

    public var title: String { self == .pixel ? "Pixel" : "Paint" }
}

/// How a layer lays over those under it, as the W3C names the modes.
public enum CanvasBlend: String, Codable, Sendable, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, hardLight, softLight, difference, exclusion, add, subtract

    public var title: String {
        switch self {
        case .colorDodge: "Color dodge"
        case .colorBurn: "Color burn"
        case .hardLight: "Hard light"
        case .softLight: "Soft light"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// A layer, but its pixels.
public struct CanvasLayer: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var name: String
    /// 0 to 255.
    public var opacity: UInt8
    public var blend: CanvasBlend
    public var hidden: Bool
    public var locked: Bool
    public var alphaLock: Bool
}

/// The canvas open, but its pixels: what the core's `view` answers.
public struct CanvasState: Codable, Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var preset: CanvasPreset
    public var palette: [[UInt8]]
    /// Bottom to top.
    public var layers: [CanvasLayer]
    /// How long each frame shows, in milliseconds: one for a still picture.
    public var frames: [UInt32]
    public var dirty: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var undo: String?
    public var redo: String?
}

/// A colour, straight RGBA.
public struct RGBA: Codable, Sendable, Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    public init(_ bytes: [UInt8]) {
        self.init(bytes.count > 0 ? bytes[0] : 0, bytes.count > 1 ? bytes[1] : 0, bytes.count > 2 ? bytes[2] : 0, bytes.count > 3 ? bytes[3] : 255)
    }

    public var array: [UInt8] { [r, g, b, a] }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(array)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([UInt8].self))
    }
}

/// A shape drawn from one pixel to another.
public enum CanvasShape: String, Codable, Sendable, CaseIterable {
    case line, rect, ellipse

    public var title: String { self == .rect ? "Rectangle" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A change to a canvas, in Proton's shape (`proton_raster::Op`): applied
/// whole or refused whole, one undo step.
public enum CanvasOp: Encodable, Sendable, Equatable {
    case addLayer(name: String, at: UInt32? = nil)
    case removeLayer(UInt32)
    case moveLayer(UInt32, to: UInt32)
    case setLayer(UInt32, name: String? = nil, opacity: UInt8? = nil, blend: CanvasBlend? = nil, hidden: Bool? = nil, locked: Bool? = nil, alphaLock: Bool? = nil)
    case fillRect(layer: UInt32, x: Int32, y: Int32, width: Int32, height: Int32, color: RGBA)
    /// A paint bucket at a pixel.
    case fill(layer: UInt32, x: Int32, y: Int32, color: RGBA, tolerance: UInt8 = 0, contiguous: Bool = true)
    case clear(layer: UInt32)
    /// A line, rectangle or ellipse from pixel `from` to pixel `to` (x, y),
    /// drawn with a pencil's tip.
    case shape(layer: UInt32, kind: CanvasShape, from: [Int32], to: [Int32], filled: Bool = false, tip: CanvasTip, color: RGBA)

    private enum Keys: String, CodingKey {
        case op, name, at, layer, to, opacity, blend, hidden, locked, alphaLock, rect, color, x, y, tolerance, contiguous
        case shape, from, filled, tip
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .addLayer(name, at):
            try c.encode("addLayer", forKey: .op)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(at, forKey: .at)
        case let .removeLayer(layer):
            try c.encode("removeLayer", forKey: .op)
            try c.encode(layer, forKey: .layer)
        case let .moveLayer(layer, to):
            try c.encode("moveLayer", forKey: .op)
            try c.encode(layer, forKey: .layer)
            try c.encode(to, forKey: .to)
        case let .setLayer(layer, name, opacity, blend, hidden, locked, alphaLock):
            try c.encode("setLayer", forKey: .op)
            try c.encode(layer, forKey: .layer)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(opacity, forKey: .opacity)
            try c.encodeIfPresent(blend, forKey: .blend)
            try c.encodeIfPresent(hidden, forKey: .hidden)
            try c.encodeIfPresent(locked, forKey: .locked)
            try c.encodeIfPresent(alphaLock, forKey: .alphaLock)
        case let .fillRect(layer, x, y, width, height, color):
            try c.encode("fillRect", forKey: .op)
            try c.encode(layer, forKey: .layer)
            try c.encode([x, y, width, height], forKey: .rect)
            try c.encode(color, forKey: .color)
        case let .fill(layer, x, y, color, tolerance, contiguous):
            try c.encode("fill", forKey: .op)
            try c.encode(layer, forKey: .layer)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(color, forKey: .color)
            try c.encode(tolerance, forKey: .tolerance)
            try c.encode(contiguous, forKey: .contiguous)
        case let .clear(layer):
            try c.encode("clear", forKey: .op)
            try c.encode(layer, forKey: .layer)
        case let .shape(layer, kind, from, to, filled, tip, color):
            try c.encode("shape", forKey: .op)
            try c.encode(layer, forKey: .layer)
            try c.encode(kind, forKey: .shape)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(filled, forKey: .filled)
            try c.encode(tip, forKey: .tip)
            try c.encode(color, forKey: .color)
        }
    }
}

/// A brush, as Proton's engine takes one: sizes in pixels, the rest 0 to
/// 100 or 1 to 255 as each says.
public struct CanvasBrush: Codable, Sendable, Equatable {
    /// Pixels across at full pressure, 1 to 1000.
    public var size: UInt32
    /// 0 fades from the middle; 100 is a hard edge.
    public var hardness: UInt8
    /// How far apart dabs fall, as a percentage of their size, 1 to 200.
    public var spacing: UInt8
    /// How much each dab covers, 1 to 255.
    public var flow: UInt8
    /// The most a stroke covers, 1 to 255.
    public var opacity: UInt8
    /// How much the pen's pressure sets the size, 0 to 100.
    public var sizePressure: UInt8
    public var flowPressure: UInt8
    public var opacityPressure: UInt8

    public init(size: UInt32 = 24, hardness: UInt8 = 60, spacing: UInt8 = 10, flow: UInt8 = 255, opacity: UInt8 = 255,
                sizePressure: UInt8 = 80, flowPressure: UInt8 = 0, opacityPressure: UInt8 = 0) {
        self.size = size
        self.hardness = hardness
        self.spacing = spacing
        self.flow = flow
        self.opacity = opacity
        self.sizePressure = sizePressure
        self.flowPressure = flowPressure
        self.opacityPressure = opacityPressure
    }
}

/// A pencil's tip: pixels across, square or round.
public struct CanvasTip: Codable, Sendable, Equatable {
    public var size: UInt32
    public var round: Bool
    public var mirror: [Int32?]

    public init(size: UInt32 = 1, round: Bool = false) {
        self.size = size
        self.round = round
        mirror = [nil, nil]
    }
}

/// How a stroke begins: on a layer, a pencil (or eraser) with a tip, or a
/// brush (or eraser) with a brush.
public struct StrokeBegin: Encodable, Sendable {
    public enum Tool: String, Encodable, Sendable { case pencil, eraser }

    public var layer: UInt32
    public var tool: Tool
    public var tip: CanvasTip?
    public var brush: CanvasBrush?
    public var color: RGBA
    public var pixelPerfect: Bool

    public init(layer: UInt32, tool: Tool, tip: CanvasTip? = nil, brush: CanvasBrush? = nil, color: RGBA, pixelPerfect: Bool = false) {
        self.layer = layer
        self.tool = tool
        self.tip = tip
        self.brush = brush
        self.color = color
        self.pixelPerfect = pixelPerfect
    }
}
