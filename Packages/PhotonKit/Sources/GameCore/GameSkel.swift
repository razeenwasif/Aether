import CoreGraphics
import Foundation
import simd

// A game's skeletons, posed: where each bone is at a moment of a clip, which
// part each slot shows and in what colour, and where a point of a part
// lands. Proton's `game-skel.js` ported; its renderer carried the points in a
// shader, Photon carries them here and draws the triangles as they land.
//
// A clip's keys are offsets from where each bone stands at rest: moved,
// turned and scaled by them, each eased from one key to the next as
// DragonBones eases (proton-game's `import::skel` writes them so). A bone's
// matrix is a, b, c, d, tx, ty — x' = a·x + c·y + tx — in the skeleton's
// pixels, y down; its world matrix its parent's times its own.

/// `.skel.json`: a skeleton as proton-game writes it, every list it leaves
/// out when empty put back.
public struct GameSkel: Decodable, Equatable, Sendable {
    public var atlas: String
    public var atlasSize: [Int]
    /// Keyframes a second: what a clip's frames are counted in.
    public var fps: Double
    /// Parents before their children.
    public var bones: [Bone]
    /// Back to front.
    public var slots: [Slot]
    public var clips: [Clip]
    public var boxes: [Box]

    public struct Bone: Decodable, Equatable, Sendable {
        public var name: String
        public var parent: Int?
        public var at: [Double]
        public var rot: Double
        public var skew: Double
        public var scale: [Double]

        enum CodingKeys: String, CodingKey { case name, parent, at, rot, skew, scale }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            parent = try c.decodeIfPresent(Int.self, forKey: .parent)
            at = try c.value(.at, [0, 0])
            rot = try c.value(.rot, 0)
            skew = try c.value(.skew, 0)
            scale = try c.value(.scale, [1, 1])
        }
    }

    public struct Slot: Decodable, Equatable, Sendable {
        public var name: String
        public var bone: Int
        /// The part shown at rest; -1 none.
        public var shown: Int
        public var color: [Double]
        public var parts: [Mesh]

        enum CodingKeys: String, CodingKey { case name, bone, shown, color, parts }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            bone = try c.value(.bone, 0)
            shown = try c.value(.shown, 0)
            color = try c.value(.color, [1, 1, 1, 1])
            parts = try c.value(.parts, [])
        }
    }

    /// A part: triangles of points.
    public struct Mesh: Decodable, Equatable, Sendable {
        public var name: String
        public var points: [Point]
        public var triangles: [[Int]]

        enum CodingKeys: String, CodingKey { case name, points, triangles }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            points = try c.value(.points, [])
            triangles = try c.value(.triangles, [])
        }
    }

    /// A point of a part: where on the atlas, in pixels, and the bones that
    /// carry it — each with how much, and where the point is on that bone.
    public struct Point: Decodable, Equatable, Sendable {
        public var uv: [Double]
        public var bones: [Carried]

        enum CodingKeys: String, CodingKey { case uv, bones }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uv = try c.value(.uv, [0, 0])
            bones = try c.value(.bones, [])
        }
    }

    /// `[bone, weight, [x, y]]`.
    public struct Carried: Decodable, Equatable, Sendable {
        public var bone: Int
        public var weight: Double
        public var at: [Double]

        public init(bone: Int, weight: Double, at: [Double]) {
            self.bone = bone
            self.weight = weight
            self.at = at
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            bone = try c.decode(Int.self)
            weight = try c.decode(Double.self)
            at = try c.decode([Double].self)
        }
    }

    public struct Box: Decodable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var slot: Int
        public var part: Int
        public var bone: Int
        public var points: [[Double]]

        enum CodingKeys: String, CodingKey { case name, kind, slot, part, bone, points }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            kind = try c.value(.kind, "hurt")
            slot = try c.value(.slot, 0)
            part = try c.value(.part, 0)
            bone = try c.value(.bone, 0)
            points = try c.value(.points, [])
        }
    }

    public struct Clip: Decodable, Equatable, Sendable {
        public var name: String
        public var frames: Int
        public var bones: [BoneTrack]
        public var slots: [SlotTrack]

        enum CodingKeys: String, CodingKey { case name, frames, bones, slots }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            frames = try c.value(.frames, 1)
            bones = try c.value(.bones, [])
            slots = try c.value(.slots, [])
        }
    }

    public struct BoneTrack: Decodable, Equatable, Sendable {
        public var bone: Int
        public var moved: [Key]
        /// Degrees, unwound so each turn goes the way it's to.
        public var turned: [Key]
        public var scaled: [Key]

        enum CodingKeys: String, CodingKey { case bone, moved, turned, scaled }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bone = try c.value(.bone, 0)
            moved = try c.value(.moved, [])
            turned = try c.value(.turned, [])
            scaled = try c.value(.scaled, [])
        }
    }

    /// A value at a frame and how it eases to the next: a bone's two
    /// numbers, or a slot's colour's four.
    public struct Key: Decodable, Equatable, Sendable {
        public var frame: Int
        public var value: [Double]
        public var ease: GameEase

        enum CodingKeys: String, CodingKey { case frame, value, color, ease }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frame = try c.value(.frame, 0)
            value = try c.decodeIfPresent([Double].self, forKey: .value) ?? c.value(.color, [0, 0])
            ease = try c.value(.ease, GameEase.linear)
        }
    }

    public struct SlotTrack: Decodable, Equatable, Sendable {
        public var slot: Int
        /// `[frame, part]`: the part shown from that frame on; -1 none.
        public var shown: [[Int]]
        public var color: [Key]

        enum CodingKeys: String, CodingKey { case slot, shown, color }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slot = try c.value(.slot, 0)
            shown = try c.value(.shown, [])
            color = try c.value(.color, [])
        }
    }

    enum CodingKeys: String, CodingKey { case atlas, atlasSize, fps, bones, slots, clips, boxes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        atlas = try c.value(.atlas, "")
        atlasSize = try c.value(.atlasSize, [0, 0])
        let fps = try c.value(.fps, 24.0)
        self.fps = fps > 0 ? fps : 24
        bones = try c.value(.bones, [])
        slots = try c.value(.slots, [])
        clips = try c.value(.clips, [])
        boxes = try c.value(.boxes, [])
    }
}

/// How a value goes from one key to the next.
public enum GameEase: Decodable, Equatable, Sendable {
    /// Holds until the next key.
    case step
    case linear
    /// Slow then fast, by how much (0 to 1).
    case easeIn(Double)
    /// Fast then slow.
    case easeOut(Double)
    /// Slow, fast, slow.
    case inOut(Double)
    /// A cubic Bézier from (0, 0) to (1, 1) through these two points.
    case bezier([Double])

    enum CodingKeys: String, CodingKey { case kind, amount, points }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let amount = try c.value(.amount, 0.0)
        switch try c.value(.kind, "linear") {
        case "step": self = .step
        case "in": self = .easeIn(amount)
        case "out": self = .easeOut(amount)
        case "inOut": self = .inOut(amount)
        case "bezier": self = .bezier(try c.value(.points, [0, 0, 1, 1]))
        default: self = .linear
        }
    }

    /// How far along a key's way to the next a value is at `p` (0–1) of it.
    public func eased(_ p: Double) -> Double {
        switch self {
        case .step: return 0
        case .linear: return p
        case .easeIn(let k): return (p * p - p) * k + p
        case .easeOut(let k): return (1 - (1 - p) * (1 - p) - p) * k + p
        case .inOut(let k): return (0.5 * (1 - cos(p * .pi)) - p) * k + p
        case .bezier(let points):
            guard points.count == 4 else { return p }
            // The curve's t where its x is p, by halving; its y there.
            func at(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
            var (lo, hi) = (0.0, 1.0)
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if at(mid, points[0], points[2]) < p { lo = mid } else { hi = mid }
            }
            return at((lo + hi) / 2, points[1], points[3])
        }
    }
}

/// A skeleton posed: each bone's world matrix (a, b, c, d, tx, ty), the part
/// each slot shows (-1 none), each slot's colour.
public struct GameSkelPose: Equatable, Sendable {
    public var bones: [[Double]]
    public var shown: [Int]
    public var colors: [[Double]]

    /// Where a point lands: each bone's place for it, by how much that bone
    /// carries it.
    public func skin(_ carried: [GameSkel.Carried]) -> CGPoint {
        var x = 0.0, y = 0.0
        for c in carried where c.bone < bones.count && c.at.count == 2 {
            let m = bones[c.bone]
            x += (m[0] * c.at[0] + m[2] * c.at[1] + m[4]) * c.weight
            y += (m[1] * c.at[0] + m[3] * c.at[1] + m[5]) * c.weight
        }
        return CGPoint(x: x, y: y)
    }
}

/// A run of triangles to draw from one texture, in world pixels: each point
/// where it lands and where on the texture (0–1) it takes its colour, and
/// what multiplies it.
public struct GameMesh: Equatable, Sendable {
    public var points: [SIMD2<Float>]
    public var uv: [SIMD2<Float>]
    public var indices: [UInt32]
    public var color: SIMD4<Float>

    public init(points: [SIMD2<Float>], uv: [SIMD2<Float>], indices: [UInt32], color: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.points = points
        self.uv = uv
        self.indices = indices
        self.color = color
    }
}

extension GameSkel {
    /// A track's value at frame `f`: its first key's before it, its last's
    /// after, and between two keys eased from one to the next.
    public static func sample(_ keys: [Key], _ f: Double, rest: [Double]) -> [Double] {
        guard let first = keys.first else { return rest }
        if f <= Double(first.frame) { return first.value }
        var i = 0
        while i + 1 < keys.count, Double(keys[i + 1].frame) <= f { i += 1 }
        if i == keys.count - 1 { return keys[i].value }
        let a = keys[i], b = keys[i + 1]
        let span = Double(b.frame - a.frame)
        let e = span > 0 ? a.ease.eased((f - Double(a.frame)) / span) : 1
        return zip(a.value, b.value).map { $0 + ($1 - $0) * e }
    }

    /// A bone's matrix from a place, a turn and a skew (degrees) and a scale.
    static func matrix(at: [Double], rot: Double, skew: Double, scale: [Double]) -> [Double] {
        let r = rot * .pi / 180, k = (rot + skew) * .pi / 180
        return [cos(r) * scale[0], sin(r) * scale[0], -sin(k) * scale[1], cos(k) * scale[1], at[0], at[1]]
    }

    /// `p` then `q`: what `q` places, placed by `p`.
    static func times(_ p: [Double], _ q: [Double]) -> [Double] {
        [p[0] * q[0] + p[2] * q[1], p[1] * q[0] + p[3] * q[1], p[0] * q[2] + p[2] * q[3], p[1] * q[2] + p[3] * q[3],
         p[0] * q[4] + p[2] * q[5] + p[4], p[1] * q[4] + p[3] * q[5] + p[5]]
    }

    /// Posed at `frame` (a clip's own frames, fractions and all) of `clip`;
    /// at rest for none.
    public func pose(_ clip: Int?, _ frame: Double) -> GameSkelPose {
        let c = clip.flatMap { $0 >= 0 && $0 < clips.count ? clips[$0] : nil }
        var world: [[Double]] = []
        for (i, b) in bones.enumerated() {
            let t = c?.bones.first { $0.bone == i }
            let moved = t.map { Self.sample($0.moved, frame, rest: [0, 0]) } ?? [0, 0]
            let turned = t.map { Self.sample($0.turned, frame, rest: [0, 0]) } ?? [0, 0]
            let scaled = t.map { Self.sample($0.scaled, frame, rest: [1, 1]) } ?? [1, 1]
            let at = [b.at[safe: 0] + moved[safe: 0], b.at[safe: 1] + moved[safe: 1]]
            let local = Self.matrix(at: at, rot: b.rot + turned[safe: 0], skew: b.skew + turned[safe: 1],
                                    scale: [(b.scale.first ?? 1) * (scaled.first ?? 1), (b.scale.count > 1 ? b.scale[1] : 1) * (scaled.count > 1 ? scaled[1] : 1)])
            if let p = b.parent, p >= 0, p < world.count { world.append(Self.times(world[p], local)) } else { world.append(local) }
        }
        var shown: [Int] = [], colors: [[Double]] = []
        for (i, s) in slots.enumerated() {
            let t = c?.slots.first { $0.slot == i }
            var part = s.shown
            for key in t?.shown ?? [] where key.count == 2 && Double(key[0]) <= frame { part = key[1] }
            shown.append(part)
            colors.append(t.map { $0.color.isEmpty ? s.color : Self.sample($0.color, frame, rest: s.color) } ?? s.color)
        }
        return GameSkelPose(bones: world, shown: shown, colors: colors)
    }

    /// Each clip's ticks at `tick` a second — proton-game's `clip_ticks`, the
    /// same rounding — as the run of a run's frames it is.
    public func clipTicks(_ tick: Int) -> [ClosedRange<Int>] {
        var from = 0
        return clips.map { c in
            let ticks = max(1, Int((Double(max(1, c.frames)) / max(1, fps) * Double(tick)).rounded(.toNearestOrAwayFromZero)))
            defer { from += ticks }
            return from...(from + ticks - 1)
        }
    }

    /// The clip, and the frame of it, a run's frame is: a run counts a
    /// skeleton's clips in ticks, one after another; at rest, its resting
    /// clip's start.
    public func moment(_ tick: Int, _ frame: Int?, chosen: [String: String] = [:]) -> (clip: Int?, frame: Double) {
        guard let frame, frame >= 0 else { return (restingClip(chosen), 0) }
        let runs = clipTicks(tick)
        guard let clip = runs.firstIndex(where: { $0.contains(frame) }) else { return (nil, 0) }
        return (clip, Double(frame - runs[clip].lowerBound) / Double(max(1, tick)) * fps)
    }

    /// The clip a skeleton rests in: the one a prefab names for idle, else
    /// one called idle, else the first.
    public func restingClip(_ chosen: [String: String] = [:]) -> Int? {
        if let name = chosen["idle"], let i = clips.firstIndex(where: { $0.name == name }) { return i }
        if let i = clips.firstIndex(where: { $0.name.lowercased() == "idle" }) { return i }
        return clips.isEmpty ? nil : 0
    }

    /// The boxes shown in a pose, their corners in the skeleton's pixels: a
    /// box is shown while its slot shows the part it is.
    public func boxes(_ posed: GameSkelPose) -> [(name: String, kind: String, points: [CGPoint])] {
        boxes.filter { $0.slot < posed.shown.count && posed.shown[$0.slot] == $0.part }.map { b in
            (b.name, b.kind, b.points.map { posed.skin([Carried(bone: b.bone, weight: 1, at: $0)]) })
        }
    }

    /// The parts a pose shows, back to front, as triangles in world pixels:
    /// the feet (`pivot`, in the skeleton's pixels) at `at`, flipped about
    /// them, and squashed or stretched about them by `scale`.
    public func meshes(_ posed: GameSkelPose, at: CGPoint, pivot: CGPoint, flip: Bool, scale: CGSize = CGSize(width: 1, height: 1)) -> [GameMesh] {
        let atlas = SIMD2<Float>(Float(max(1, atlasSize.first ?? 1)), Float(max(1, atlasSize.count > 1 ? atlasSize[1] : 1)))
        let sx = (flip ? -1 : 1) * scale.width, sy = scale.height
        var out: [GameMesh] = []
        for (i, slot) in slots.enumerated() {
            let part = i < posed.shown.count ? posed.shown[i] : -1
            guard part >= 0, part < slot.parts.count else { continue }
            let mesh = slot.parts[part]
            guard !mesh.points.isEmpty, !mesh.triangles.isEmpty else { continue }
            let points = mesh.points.map { p -> SIMD2<Float> in
                let q = posed.skin(Array(p.bones.prefix(4)))
                return SIMD2(Float(at.x + (q.x - pivot.x) * sx), Float(at.y + (q.y - pivot.y) * sy))
            }
            let uv = mesh.points.map { SIMD2(Float($0.uv[safe: 0]), Float($0.uv[safe: 1])) / atlas }
            let indices = mesh.triangles.flatMap { t in t.count == 3 && t.allSatisfy({ $0 >= 0 && $0 < points.count }) ? t.map { UInt32($0) } : [] }
            let c = i < posed.colors.count ? posed.colors[i] : [1, 1, 1, 1]
            out.append(GameMesh(points: points, uv: uv, indices: indices,
                                color: SIMD4(Float(c[safe: 0]), Float(c[safe: 1]), Float(c[safe: 2]), Float(c.count > 3 ? c[3] : 1))))
        }
        return out
    }
}

extension Array where Element == Double {
    /// The value at `i`, or 0 past the end.
    subscript(safe i: Int) -> Double { i < count ? self[i] : 0 }
}
