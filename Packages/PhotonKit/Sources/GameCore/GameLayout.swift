import CoreGraphics
import Foundation
import simd

// What a room draws, as arithmetic: the sprites back to front and the lights
// that fall on them, for a camera. No GPU here: the renderer draws the list
// this makes, and the tests check it. Proton's `game-scene.js` (`layout`,
// `lightingOf`, `flickerOf`, `frameSprite`), ported.

/// How the stage looks at the world. The renderer takes only the matrix it
/// makes, so a projection is a setting, not a renderer: side-on is the only
/// one so far; isometric and orthographic 3D come with their slices (plan
/// §9b).
public struct GameCamera: Equatable, Sendable {
    public enum Projection: Equatable, Sendable {
        /// Looking straight at the planes, x right and y down, in room pixels.
        case sideOn
    }

    public var projection: Projection = .sideOn
    /// The world point at the middle of what's drawn.
    public var center: CGPoint
    /// Pixels drawn a world pixel.
    public var zoom: Double

    public init(projection: Projection = .sideOn, center: CGPoint, zoom: Double) {
        self.projection = projection
        self.center = center
        self.zoom = zoom
    }

    /// World to clip space for a target `size` pixels.
    public func matrix(target size: CGSize) -> simd_float4x4 {
        let sx = Float(2 * zoom / max(1, size.width)), sy = Float(-2 * zoom / max(1, size.height))
        let tx = Float(-center.x) * sx, ty = Float(-center.y) * sy
        return simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(tx, ty, 0, 1)))
    }

    /// The camera moved so the target's left and top edges fall on whole
    /// world pixels: pixel art drawn at its own size stays on its grid.
    public func snapped(target size: CGSize) -> GameCamera {
        var c = self
        let halfW = size.width / 2 / zoom, halfH = size.height / 2 / zoom
        c.center = CGPoint(x: (center.x - halfW).rounded() + halfW, y: (center.y - halfH).rounded() + halfH)
        return c
    }
}

/// One thing to draw, in world pixels: rotated about its middle, flipped by
/// swapping its sides, hazed toward `tint` by `tint.w`. Lit, the room's
/// lights shade it, through its `normal` map when it has one.
public struct GameSprite: Equatable, Sendable {
    /// The image, by its path in the game; `GameSprite.glow` for the
    /// renderer's own soft disc.
    public var key: String
    public var normal: String?
    public var rect: CGRect
    /// The part of its texture it is (a frame of a sheet), 0–1.
    public var uv = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Degrees.
    public var rot: Double = 0
    public var flip = false
    public var opacity: Double = 1
    public var tint = SIMD4<Float>(0, 0, 0, 0)
    /// `normal`, `add`, `multiply` or `screen`.
    public var blend = "normal"
    public var lit = false
    /// A skeleton's part: triangles where the pose puts them, drawn from
    /// `key` instead of the rectangle (which bounds them).
    public var mesh: GameMesh?

    public static let glow = "#glow"

    public init(key: String, normal: String? = nil, rect: CGRect, uv: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), rot: Double = 0, flip: Bool = false,
                opacity: Double = 1, tint: SIMD4<Float> = .zero, blend: String = "normal", lit: Bool = false, mesh: GameMesh? = nil) {
        self.key = key
        self.normal = normal
        self.rect = rect
        self.uv = uv
        self.rot = rot
        self.flip = flip
        self.opacity = opacity
        self.tint = tint
        self.blend = blend
        self.lit = lit
        self.mesh = mesh
    }
}

/// A light as the renderer takes it: where in world pixels, its reach, how
/// high it hangs, its colour times its intensity.
public struct GameLamp: Equatable, Sendable {
    public var at: CGPoint
    public var radius: Double
    public var height: Double
    public var color: SIMD3<Float>
}

/// How a frame is lit: the ambient colour where no light falls, and the
/// lights nearest the camera, at most `GameLighting.most`.
public struct GameLighting: Equatable, Sendable {
    public static let most = 16
    public var ambient = SIMD3<Float>(1, 1, 1)
    public var lamps: [GameLamp] = []

    public init(ambient: SIMD3<Float> = SIMD3(1, 1, 1), lamps: [GameLamp] = []) {
        self.ambient = ambient
        self.lamps = lamps
    }
}

/// Something standing on the play plane: an image, an animation's frame or
/// a skeleton posed, on its feet (`frame` nil at rest), just hurt (`flash`,
/// drawn white) or spared for now (`blink`, faint), squashed or stretched
/// about its feet by `scale`. A shot with no image is a glow `glow` across,
/// its middle at `at`.
public struct GameStanding: Equatable, Sendable {
    public var key: String
    public var at: CGPoint
    public var pivot: CGPoint
    public var flip = false
    public var frame: Int?
    public var flash = false
    public var blink = false
    public var glow: Double?
    public var scale: CGSize?
    /// The clips its prefab chose for each state, for the one it rests in.
    public var clips: [String: String] = [:]

    public init(key: String, at: CGPoint, pivot: CGPoint, flip: Bool = false, frame: Int? = nil, flash: Bool = false, blink: Bool = false, glow: Double? = nil,
                scale: CGSize? = nil, clips: [String: String] = [:]) {
        self.key = key
        self.at = at
        self.pivot = pivot
        self.flip = flip
        self.frame = frame
        self.flash = flash
        self.blink = blink
        self.glow = glow
        self.scale = scale
        self.clips = clips
    }
}

/// What the layout asks of the game's art: an image's size, how an image is
/// cut up, an animation, a skeleton. What isn't loaded yet is left out.
public struct GameArt {
    public var size: (String) -> CGSize?
    public var parts: (String) -> GameImageParts?
    public var anim: (String) -> GameAnim?
    public var skel: (String) -> GameSkel?

    public init(size: @escaping (String) -> CGSize?, parts: @escaping (String) -> GameImageParts? = { _ in nil }, anim: @escaping (String) -> GameAnim? = { _ in nil },
                skel: @escaping (String) -> GameSkel? = { _ in nil }) {
        self.size = size
        self.parts = parts
        self.anim = anim
        self.skel = skel
    }
}

extension GameScene {
    /// What stands, in the order an isometric ground is seen: the furthest
    /// up the screen first, so what's nearer is drawn over it. Two at one
    /// height keep the order they came in.
    public static func byDepth(_ standing: [GameStanding]) -> [GameStanding] {
        standing.enumerated().sorted { ($0.element.at.y, $0.offset) < ($1.element.at.y, $1.offset) }.map(\.element)
    }

    /// The ways a line is drawn with Shift held: on an isometric ground,
    /// across, up and down, and along the 2:1 diagonals; side-on, across,
    /// up and down, and at 45°.
    public static func ways(isometric: Bool) -> [CGVector] {
        let diagonal = isometric ? CGVector(dx: 2, dy: 1) : CGVector(dx: 1, dy: 1)
        return [CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), diagonal, CGVector(dx: -diagonal.dx, dy: diagonal.dy)]
    }

    /// `p` brought onto the nearest of `ways` from `from`: as far along it
    /// as `p` is.
    public static func snap(_ p: CGPoint, from: CGPoint, isometric: Bool) -> CGPoint {
        let d = CGVector(dx: p.x - from.x, dy: p.y - from.y)
        var best = (CGPoint.zero, -Double.infinity)
        for way in ways(isometric: isometric) {
            let length = hypot(way.dx, way.dy)
            let along = (d.dx * way.dx + d.dy * way.dy) / length
            // The nearer the way, the more of `d` lies along it.
            if abs(along) > best.1 {
                best = (CGPoint(x: from.x + way.dx / length * along, y: from.y + way.dy / length * along), abs(along))
            }
        }
        return CGPoint(x: best.0.x.rounded(), y: best.0.y.rounded())
    }

    /// An isometric ground's grid over a room `size` big: lines along the
    /// two 2:1 diagonals, a flag 128 across and 64 deep, from the room's
    /// corner. Each a pair of ends.
    public static func grid(_ size: CGSize, across: Double = 128) -> [(CGPoint, CGPoint)] {
        let deep = across / 2
        var out: [(CGPoint, CGPoint)] = []
        // y = k·deep − x/2 and y = k·deep + x/2, over the room.
        let lowest = Int((-size.width / 2 / deep).rounded(.down)), highest = Int(((size.height + size.width / 2) / deep).rounded(.up))
        for k in lowest...highest {
            let c = Double(k) * deep
            for slope in [-0.5, 0.5] {
                // Where it crosses x = 0 and x = width, clipped to the room's height.
                var ends: [CGPoint] = []
                for x in [0.0, size.width] { ends.append(CGPoint(x: x, y: c + slope * x)) }
                for y in [0.0, size.height] { ends.append(CGPoint(x: (y - c) / slope, y: y)) }
                let inside = ends.filter { $0.x >= -0.5 && $0.x <= size.width + 0.5 && $0.y >= -0.5 && $0.y <= size.height + 0.5 }
                guard let first = inside.min(by: { $0.x < $1.x }), let last = inside.max(by: { $0.x < $1.x }), last.x - first.x > 0.5 else { continue }
                out.append((first, last))
            }
        }
        return out
    }

    /// Everything a room draws, back to front, in world pixels, for the game
    /// camera centred at `center`: each plane's art shifted by its parallax
    /// and hazed, what stands on the play plane in front of its art, a lit
    /// plane's sprites marked lit, and the halos of its lights after it.
    /// `time` (seconds of the run) wavers lights; nil holds them still.
    /// `air` is the moment the room's particles are shown at (none when
    /// nil), and `sparks` are bursts begun by what happened, flying on the
    /// play plane in front of what stands there. `snap` keeps pixel art on
    /// whole pixels. `tick` is the run's ticks a second, which a
    /// skeleton's frames are counted in. `depth` draws what stands in
    /// order of its feet, the furthest up the screen first, as an
    /// isometric game's ground is seen.
    public static func layout(_ room: GameRoom, focal: Double, view: CGSize, center: CGPoint, art: GameArt,
                              standing: [GameStanding] = [], time: Double? = nil, air: Double? = nil, sparks: [GameSpark] = [],
                              snap: Bool = false, tick: Int = 60, depth: Bool = false) -> [GameSprite] {
        let standing = depth ? Self.byDepth(standing) : standing
        let corner = corner(room, view: view, center: center)
        var out: [GameSprite] = []
        for plane in room.planes {
            var shift = shift(factor(plane, focal: focal), corner: corner)
            if snap { shift = CGPoint(x: shift.x.rounded(), y: shift.y.rounded()) }
            let (hr, hg, hb, ha) = haze(room, plane)
            let tint = SIMD4<Float>(Float(hr), Float(hg), Float(hb), Float(ha))
            let first = out.count
            for item in plane.items {
                let blend = item.blend != "normal" ? item.blend : plane.blend
                let x = Double(item.at.first ?? 0) + shift.x, y = Double(item.at.count > 1 ? item.at[1] : 0) + shift.y
                if item.image.hasSuffix(".img.json") {
                    if let parts = art.parts(item.image) { out += pieces(item, parts, art: art, x: x, y: y, tint: tint, blend: blend) }
                    continue
                }
                guard let size = art.size(item.image) else { continue }
                out.append(GameSprite(key: item.image, rect: CGRect(x: x, y: y, width: size.width * item.scale, height: size.height * item.scale),
                                      rot: item.rot, flip: item.flip, opacity: item.opacity, tint: tint, blend: blend))
            }
            if plane.gameplay {
                for s in standing {
                    for var sprite in sprites(s, art: art, tick: tick) {
                        if snap, sprite.mesh == nil { sprite.rect.origin = CGPoint(x: sprite.rect.minX.rounded(), y: sprite.rect.minY.rounded()) }
                        if s.flash { sprite.tint = SIMD4(1, 1, 1, 0.85) }
                        if s.blink { sprite.opacity = 0.35 }
                        out.append(sprite)
                    }
                }
                for spark in sparks { out += GameFX.burst(spark, time: time ?? 0) }
            }
            // The room's air on this plane, over what the camera sees of it.
            if let air {
                let f = factor(plane, focal: focal)
                let seen = CGRect(x: corner.x * f, y: corner.y * f, width: view.width, height: view.height)
                for (i, emitter) in room.particles.enumerated() where emitter.plane == plane.id {
                    for var mote in GameFX.air(emitter.preset, over: seen, time: air, seed: GameFX.seed("\(room.id):\(i)")) {
                        mote.rect.origin.x += shift.x
                        mote.rect.origin.y += shift.y
                        out.append(mote)
                    }
                }
            }
            if plane.lit { for i in first..<out.count where out[i].key != GameSprite.glow || out[i].blend != "add" { out[i].lit = true } }
            // The halos of the lights standing on it, in the air before it.
            for light in room.lights where light.plane == plane.id && light.glow > 0 {
                let r = Double(light.radius) * 0.6
                let at = CGPoint(x: Double(light.at.first ?? 0) + shift.x, y: Double(light.at.count > 1 ? light.at[1] : 0) + shift.y)
                let (cr, cg, cb) = rgb(light.color)
                out.append(GameSprite(key: GameSprite.glow, rect: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2),
                                      opacity: min(1, light.glow * light.intensity * flicker(light, time: time)),
                                      tint: SIMD4(Float(cr), Float(cg), Float(cb), 1), blend: "add"))
            }
        }
        return out
    }

    /// A room's light for the camera at `center`: its ambient (white when
    /// not said), and its lights where their planes' parallax puts them,
    /// nearest the camera's middle first, at most as many as the renderer
    /// takes.
    public static func lighting(_ room: GameRoom, focal: Double, view: CGSize, center: CGPoint, time: Double? = nil) -> GameLighting {
        let corner = corner(room, view: view, center: center)
        let lamps = room.lights.map { light -> GameLamp in
            let shift = room.planes.first { $0.id == light.plane }.map { self.shift(factor($0, focal: focal), corner: corner) } ?? .zero
            let k = Float(light.intensity * flicker(light, time: time))
            let (r, g, b) = rgb(light.color)
            return GameLamp(at: CGPoint(x: Double(light.at.first ?? 0) + shift.x, y: Double(light.at.count > 1 ? light.at[1] : 0) + shift.y),
                            radius: Double(light.radius), height: light.height, color: SIMD3(Float(r), Float(g), Float(b)) * k)
        }
        .sorted { hypot($0.at.x - center.x, $0.at.y - center.y) < hypot($1.at.x - center.x, $1.at.y - center.y) }
        let (r, g, b) = rgb(room.ambient ?? "#ffffff")
        return GameLighting(ambient: SIMD3(Float(r), Float(g), Float(b)), lamps: Array(lamps.prefix(GameLighting.most)))
    }

    /// How bright a wavering light is at `time` seconds (1 when still): a few
    /// sines out of step, the same every time for the same light.
    public static func flicker(_ light: GameLight, time: Double?) -> Double {
        guard light.flicker > 0, let time else { return 1 }
        var h = 0
        for c in light.id.utf16 { h = (h * 31 + Int(c)) % 997 }
        let k = Double(h)
        let wave = 0.5 * sin(time * 11 + k) + 0.3 * sin(time * 17.3 + k * 1.7) + 0.2 * sin(time * 31.7 + k * 2.3)
        return 1 - light.flicker * (0.5 + 0.5 * wave)
    }

    /// What stands at `s.at`, as sprites: a skeleton posed (a sprite a part
    /// it shows), or the one sprite `sprite` makes. None while what it's
    /// drawn from isn't loaded.
    public static func sprites(_ s: GameStanding, art: GameArt, tick: Int = 60) -> [GameSprite] {
        guard s.glow == nil, s.key.hasSuffix(".skel.json") else { return sprite(s, art: art).map { [$0] } ?? [] }
        guard let skel = art.skel(s.key), art.size(skel.atlas) != nil else { return [] }
        let m = skel.moment(tick, s.frame, chosen: s.clips)
        let meshes = skel.meshes(skel.pose(m.clip, m.frame), at: s.at, pivot: s.pivot, flip: s.flip, scale: s.scale ?? CGSize(width: 1, height: 1))
        return meshes.map { mesh in
            let xs = mesh.points.map { Double($0.x) }, ys = mesh.points.map { Double($0.y) }
            let bounds = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            return GameSprite(key: skel.atlas, rect: bounds, flip: s.flip, mesh: mesh)
        }
    }

    /// Where what stands at `s.at` is drawn, all of it: for finding it under
    /// the pointer.
    public static func bounds(_ s: GameStanding, art: GameArt, tick: Int = 60) -> CGRect? {
        let all = sprites(s, art: art, tick: tick)
        guard let first = all.first else { return nil }
        return all.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// What stands at `s.at` as a sprite: an animation's frame (the part of
    /// its sheet it is), an image on its feet, or a shot's glow, squashed or
    /// stretched about its feet. None while what it's drawn from isn't
    /// loaded, and none for a skeleton (`sprites` poses one).
    public static func sprite(_ s: GameStanding, art: GameArt) -> GameSprite? {
        guard var out = unsquashed(s, art: art) else { return nil }
        if let k = s.scale, s.glow == nil, k != CGSize(width: 1, height: 1) {
            out.rect = CGRect(x: s.at.x + (out.rect.minX - s.at.x) * k.width, y: s.at.y + (out.rect.minY - s.at.y) * k.height,
                              width: out.rect.width * k.width, height: out.rect.height * k.height)
        }
        return out
    }

    private static func unsquashed(_ s: GameStanding, art: GameArt) -> GameSprite? {
        if let glow = s.glow {
            let r = glow / 2
            return GameSprite(key: GameSprite.glow, rect: CGRect(x: s.at.x - r, y: s.at.y - r, width: r * 2, height: r * 2), tint: SIMD4(1, 0.55, 0.3, 1), blend: "add")
        }
        if s.key.hasSuffix(".anim.json") {
            guard let anim = art.anim(s.key) else { return nil }
            let index = s.frame ?? anim.restingFrame(s.clips)
            guard index >= 0, index < anim.frames.count else { return nil }
            let f = anim.frames[index]
            guard f.rect.count == 4, f.rect[2] > 0, f.rect[3] > 0, f.sheet < anim.sheets.count, let sheet = art.size(anim.sheets[f.sheet]) else { return nil }
            let uv = CGRect(x: Double(f.rect[0]) / sheet.width, y: Double(f.rect[1]) / sheet.height, width: Double(f.rect[2]) / sheet.width, height: Double(f.rect[3]) / sheet.height)
            return GameSprite(key: anim.sheets[f.sheet], rect: animFrame(f, at: s.at, pivot: s.pivot, flip: s.flip), uv: uv, flip: s.flip)
        }
        guard let size = art.size(s.key) else { return nil }
        return GameSprite(key: s.key, rect: stillFrame(size: size, at: s.at, pivot: s.pivot, flip: s.flip), flip: s.flip)
    }

    /// An image cut up, as its pieces: each placed, flipped and turned as its
    /// part of the whole is, about the whole's middle; with its normal map's
    /// piece where it has one.
    static func pieces(_ item: GameItem, _ parts: GameImageParts, art: GameArt, x: Double, y: Double, tint: SIMD4<Float>, blend: String) -> [GameSprite] {
        let s = item.scale
        let whole = CGRect(x: x, y: y, width: Double(parts.size.first ?? 0) * s, height: Double(parts.size.count > 1 ? parts.size[1] : 0) * s)
        let a = item.rot * .pi / 180
        return parts.chunks.compactMap { c -> GameSprite? in
            guard art.size(c.file) != nil, c.at.count == 2, c.size.count == 2 else { return nil }
            let normal = parts.normal.first { $0.at == c.at }?.file
            let (w, h) = (Double(c.size[0]) * s, Double(c.size[1]) * s)
            let left = item.flip ? whole.width - Double(c.at[0]) * s - w : Double(c.at[0]) * s
            // From the whole's middle to the piece's, turned with the whole.
            let dx = left + w / 2 - whole.width / 2, dy = Double(c.at[1]) * s + h / 2 - whole.height / 2
            let cx = whole.midX + dx * cos(a) - dy * sin(a), cy = whole.midY + dx * sin(a) + dy * cos(a)
            return GameSprite(key: c.file, normal: normal.flatMap { art.size($0) != nil ? $0 : nil }, rect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                              rot: item.rot, flip: item.flip, opacity: item.opacity, tint: tint, blend: blend)
        }
    }
}
