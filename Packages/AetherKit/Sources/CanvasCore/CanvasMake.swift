import Foundation

/// A sprite template: a ship, a creature or an item, mirrored down its middle.
public enum CanvasSpriteKind: String, CaseIterable, Codable, Sendable {
    case ship, creature, item

    public var title: String {
        switch self {
        case .ship: "A ship"
        case .creature: "A creature"
        case .item: "An item"
        }
    }

    /// Its size at scale 1, to put it in the middle: Proton's `SPRITES`.
    public var size: (width: Int32, height: Int32) {
        switch self {
        case .ship: (14, 14)
        case .creature: (14, 12)
        case .item: (12, 12)
        }
    }
}

public enum CanvasNoiseKind: String, CaseIterable, Codable, Sendable {
    case gradient, value

    public var title: String { self == .gradient ? "Gradient" : "Value" }
}

/// How noise's values become colours.
public enum CanvasNoiseMix: String, CaseIterable, Codable, Sendable {
    case dither, nearest, smooth

    public var title: String {
        switch self {
        case .dither: "Dithered"
        case .nearest: "Banded"
        case .smooth: "Smooth"
        }
    }
}

/// A generator's picture laid over a layer, held to what is selected
/// (`proton_raster::gen::Generator`).
public enum CanvasGenerator: Encodable, Sendable, Equatable {
    /// A sprite from a template and a seed, its top left at `at`, each of
    /// its pixels `scale` square; in `color`'s ramp, or a hue of the seed's.
    case sprite(template: CanvasSpriteKind, seed: UInt32, at: [Int32], scale: UInt32, color: RGBA?)
    /// Noise in `colors`, low to high, in cells `cell` pixels across.
    case noise(CanvasNoiseKind, seed: UInt32, cell: UInt32, octaves: UInt32, colors: [RGBA], mix: CanvasNoiseMix, dither: UInt32)
    /// Caves: rock in `color`, `density` percent to start, smoothed `steps`
    /// times, in cells `cell` pixels across; wrapped, a tile that repeats.
    case cave(seed: UInt32, density: UInt8, steps: UInt8, cell: UInt32, wrap: Bool, color: RGBA)

    private enum Keys: String, CodingKey {
        case kind, template, seed, at, scale, color, noise, cell, octaves, colors, mix, dither, density, steps, wrap
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .sprite(template, seed, at, scale, color):
            try c.encode("sprite", forKey: .kind)
            try c.encode(template, forKey: .template)
            try c.encode(seed, forKey: .seed)
            try c.encode(at, forKey: .at)
            try c.encode(scale, forKey: .scale)
            try c.encodeIfPresent(color, forKey: .color)
        case let .noise(kind, seed, cell, octaves, colors, mix, dither):
            try c.encode("noise", forKey: .kind)
            try c.encode(kind, forKey: .noise)
            try c.encode(seed, forKey: .seed)
            try c.encode(cell, forKey: .cell)
            try c.encode(octaves, forKey: .octaves)
            try c.encode(colors, forKey: .colors)
            try c.encode(mix, forKey: .mix)
            try c.encode(dither, forKey: .dither)
        case let .cave(seed, density, steps, cell, wrap, color):
            try c.encode("cave", forKey: .kind)
            try c.encode(seed, forKey: .seed)
            try c.encode(density, forKey: .density)
            try c.encode(steps, forKey: .steps)
            try c.encode(cell, forKey: .cell)
            try c.encode(wrap, forKey: .wrap)
            try c.encode(color, forKey: .color)
        }
    }
}

/// A layer made over, held to what is selected (`proton_raster::Filter`).
public enum CanvasFilter: Encodable, Sendable, Equatable {
    /// A line of `color` round what is there, or on its own edge `inside`.
    case outline(color: RGBA, diagonal: Bool, inside: Bool)
    /// What is there cast `dx`, `dy` off in `color`, under it, blurred.
    case shadow(dx: Int32, dy: Int32, color: RGBA, blur: UInt32)
    /// Squares `size` pixels across, each the average of what was in it.
    case pixelate(size: UInt32)
    /// Every pixel the nearest of `colors` colours (or of the palette),
    /// dithered `dither` across (0: not); kept, they become the palette.
    case quantize(colors: UInt32, palette: Bool, dither: UInt32, keep: Bool)

    private enum Keys: String, CodingKey {
        case kind, color, diagonal, inside, dx, dy, blur, size, colors, palette, dither, keep
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .outline(color, diagonal, inside):
            try c.encode("outline", forKey: .kind)
            try c.encode(color, forKey: .color)
            try c.encode(diagonal, forKey: .diagonal)
            try c.encode(inside, forKey: .inside)
        case let .shadow(dx, dy, color, blur):
            try c.encode("shadow", forKey: .kind)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
            try c.encode(color, forKey: .color)
            try c.encode(blur, forKey: .blur)
        case .pixelate(let size):
            try c.encode("pixelate", forKey: .kind)
            try c.encode(size, forKey: .size)
        case let .quantize(colors, palette, dither, keep):
            try c.encode("quantize", forKey: .kind)
            try c.encode(colors, forKey: .colors)
            try c.encode(palette, forKey: .palette)
            try c.encode(dither, forKey: .dither)
            try c.encode(keep, forKey: .keep)
        }
    }
}

/// What a canvas is written out as.
public enum CanvasExportFormat: String, CaseIterable, Sendable {
    /// The frame shown, flattened.
    case png
    /// Every frame on one sheet, with Aseprite's JSON beside it.
    case sheet
    /// The frame shown, its layers kept.
    case psd

    public var title: String {
        switch self {
        case .png: "PNG"
        case .sheet: "Sprite sheet"
        case .psd: "Photoshop"
        }
    }
}
