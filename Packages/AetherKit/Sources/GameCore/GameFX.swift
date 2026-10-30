import CoreGraphics
import Foundation

// Particles: what hangs in a room's air (motes, rain, snow, leaves, embers,
// dust) and what flies from what happens (dust as the player lands and
// jumps, sparks as a blow lands, a burst as a thing is beaten). Proton's
// `game-fx.js`, ported.
//
// Every particle is a closed function of time and a seed: where it is at a
// moment is worked out from that moment, never stepped from the frame
// before, so a run played back shows the same particles at the same ticks
// whatever the frame rate. Nothing here touches the run: particles are only
// drawn, as the renderer's soft glow, tinted (stretched for rain). Sizes and
// speeds are a 1080-pixel-high view's, scaled to the game's own, so a
// pixel-art game's dust is as big against its player as a painted one's.

/// Particles that hang in a room: an `ambience.particles` entry.
public struct GameEmitter: Decodable, Equatable, Sendable {
    public var preset: String
    public var plane: String

    public init(preset: String, plane: String) {
        self.preset = preset
        self.plane = plane
    }

    enum CodingKeys: String, CodingKey { case preset, plane }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? ""
        plane = try c.decodeIfPresent(String.self, forKey: .plane) ?? ""
    }
}

/// A burst begun: of a kind, from a point, at a moment of the run, seeded,
/// turned to face left when `flip`, for a view `tall` pixels high.
public struct GameSpark: Equatable, Sendable {
    public var kind: String
    public var at: CGPoint
    public var start: Double
    public var seed: Int32
    public var flip = false
    public var tall: Double = 1080

    public init(kind: String, at: CGPoint, start: Double, seed: Int32, flip: Bool = false, tall: Double = 1080) {
        self.kind = kind
        self.at = at
        self.start = start
        self.seed = seed
        self.flip = flip
        self.tall = tall
    }
}

/// What a tick says happened, a bit each (the runtime's).
public enum GameHappened {
    public static let jumped: UInt32 = 1
    public static let landed: UInt32 = 2
    public static let dashed: UInt32 = 4
    public static let hurt: UInt32 = 8
    public static let hit: UInt32 = 256
    public static let killed: UInt32 = 512
    public static let died: UInt32 = 1024
    public static let rested: UInt32 = 2048
}

public enum GameFX {
    /// The view height the presets are sized for.
    static let tall = 1080.0

    /// What hangs in the air: how many over the view, how big, how fast
    /// across and down (pixels a second, a range each), how far it sways and
    /// how fast, its colour, how opaque, how it blends, whether it twinkles,
    /// and for rain how long a streak.
    struct Air {
        var count: Int
        var size: (Double, Double)
        var vx: (Double, Double)
        var vy: (Double, Double)
        var sway: Double
        var swing: Double
        var color: String
        var alpha: (Double, Double)
        var blend: String
        var twinkle: Double
        var streak: (Double, Double)?
        var spin = false
    }

    static let air: [String: Air] = [
        "motes": Air(count: 36, size: (7, 16), vx: (-16, 16), vy: (-30, -8), sway: 24, swing: 0.4, color: "#fff2c8", alpha: (0.25, 0.7), blend: "add", twinkle: 0.6),
        "rain": Air(count: 140, size: (3, 5), vx: (-160, -120), vy: (1800, 2200), sway: 0, swing: 0, color: "#aac4ff", alpha: (0.2, 0.4), blend: "normal", twinkle: 0, streak: (40, 70)),
        "snow": Air(count: 90, size: (6, 13), vx: (-40, 40), vy: (80, 160), sway: 40, swing: 0.5, color: "#ffffff", alpha: (0.5, 0.9), blend: "normal", twinkle: 0),
        "leaves": Air(count: 24, size: (14, 24), vx: (40, 120), vy: (80, 180), sway: 80, swing: 0.7, color: "#c98a3c", alpha: (0.7, 1), blend: "normal", twinkle: 0, spin: true),
        "embers": Air(count: 40, size: (4, 10), vx: (-30, 30), vy: (-180, -80), sway: 20, swing: 1.1, color: "#ff8a3c", alpha: (0.4, 0.95), blend: "add", twinkle: 1),
        "dust": Air(count: 30, size: (4, 9), vx: (10, 40), vy: (-6, 6), sway: 12, swing: 0.3, color: "#d8ccb0", alpha: (0.15, 0.35), blend: "normal", twinkle: 0.2),
    ]

    /// What flies from a moment: how many, how fast, which ways (radians,
    /// y down, before a facing turns them), how hard it falls, how long each
    /// lives, how big, its colour, how opaque, how it blends.
    struct Burst {
        var count: Int
        var speed: (Double, Double)
        var angle: (Double, Double)
        var gravity: Double
        var life: (Double, Double)
        var size: (Double, Double)
        var color: String
        var alpha: Double
        var blend: String
    }

    static let bursts: [String: Burst] = [
        "land": Burst(count: 12, speed: (80, 260), angle: (.pi * 0.95, .pi * 1.05), gravity: 520, life: (0.25, 0.45), size: (8, 16), color: "#d8ccb0", alpha: 0.55, blend: "normal"),
        "jump": Burst(count: 7, speed: (60, 180), angle: (.pi * 0.9, .pi * 1.1), gravity: 400, life: (0.2, 0.35), size: (6, 12), color: "#d8ccb0", alpha: 0.45, blend: "normal"),
        "dash": Burst(count: 12, speed: (120, 320), angle: (.pi * 0.9, .pi * 1.1), gravity: 0, life: (0.15, 0.3), size: (6, 12), color: "#cfe3ff", alpha: 0.6, blend: "add"),
        "hit": Burst(count: 14, speed: (320, 800), angle: (0, .pi * 2), gravity: 1200, life: (0.12, 0.3), size: (6, 12), color: "#fff4d0", alpha: 0.95, blend: "add"),
        "kill": Burst(count: 26, speed: (160, 640), angle: (0, .pi * 2), gravity: 760, life: (0.35, 0.8), size: (8, 20), color: "#ffb070", alpha: 0.9, blend: "add"),
        "hurt": Burst(count: 14, speed: (200, 520), angle: (0, .pi * 2), gravity: 840, life: (0.2, 0.45), size: (6, 14), color: "#ff5a6a", alpha: 0.9, blend: "add"),
        "rest": Burst(count: 18, speed: (40, 120), angle: (-.pi * 0.8, -.pi * 0.2), gravity: -80, life: (0.8, 1.4), size: (8, 14), color: "#9fe0ff", alpha: 0.8, blend: "add"),
    ]

    /// The kinds of air a room can hang on a plane.
    public static var presets: [String] { air.keys.sorted() }

    /// A number from 0 to 1, always the same for the same three (Proton's,
    /// in its 32-bit arithmetic).
    public static func noise(_ seed: Int32, _ i: Int, _ k: Int) -> Double {
        func imul(_ a: UInt32, _ b: UInt32) -> UInt32 { a &* b }
        var h = imul(UInt32(bitPattern: seed), 0x9e37_79b1) ^ imul(UInt32(truncatingIfNeeded: i), 0x85eb_ca6b) ^ imul(UInt32(truncatingIfNeeded: k), 0xc2b2_ae35)
        h = imul(h ^ (h >> 16), 0x7feb_352d)
        h = imul(h ^ (h >> 15), 0x846c_a68b)
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }

    /// A seed from a name: a room's, a burst's.
    public static func seed(_ text: String) -> Int32 {
        var h: UInt32 = 2_166_136_261
        for c in text.utf16 { h = (h ^ UInt32(c)) &* 16_777_619 }
        return Int32(bitPattern: h)
    }

    private static func within(_ r: (Double, Double), _ t: Double) -> Double { r.0 + (r.1 - r.0) * t }
    private static func wrap(_ v: Double, _ m: Double) -> Double { (v.truncatingRemainder(dividingBy: m) + m).truncatingRemainder(dividingBy: m) }
    private static func tint(_ hex: String) -> SIMD4<Float> {
        let (r, g, b) = GameScene.rgb(hex)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    /// A room's air at `time` seconds over `rect`, the part of its plane the
    /// camera sees, in the plane's own pixels: laid in a tile from the
    /// room's origin, so each mote stays where it is in the world and comes
    /// round again past the edge. None for a kind there isn't.
    public static func air(_ preset: String, over rect: CGRect, time: Double, seed: Int32) -> [GameSprite] {
        guard let p = air[preset], rect.height > 0 else { return [] }
        // The tile: the view and a margin, so nothing pops in or out in sight.
        let margin = 48.0
        let (w, h) = (rect.width + margin * 2, rect.height + margin * 2)
        let k = rect.height / tall
        let count = Int((Double(p.count) * max(0.25, min(4, rect.width / rect.height / (16.0 / 9)))).rounded())
        let colour = tint(p.color)
        return (0..<count).map { i in
            func r(_ n: Int) -> Double { noise(seed, i, n) }
            let vx = within(p.vx, r(2)) * k, vy = within(p.vy, r(3)) * k
            let sway = p.sway * k * sin(time * p.swing * (0.6 + r(4)) * .pi * 2 + r(5) * .pi * 2)
            let x = rect.minX - margin + wrap(r(0) * w + vx * time + sway - (rect.minX - margin), w)
            let y = rect.minY - margin + wrap(r(1) * h + vy * time - (rect.minY - margin), h)
            let size = within(p.size, r(6)) * k
            let twinkle = p.twinkle > 0 ? 1 - p.twinkle * 0.5 * (1 + sin(time * (1.5 + r(7) * 2) * .pi + r(8) * .pi * 2)) : 1
            let opacity = within(p.alpha, r(9)) * twinkle
            if let streak = p.streak {
                // A streak along the way it falls.
                let length = within(streak, r(6)) * k
                return GameSprite(key: GameSprite.glow, rect: CGRect(x: x - size / 2, y: y - length / 2, width: size, height: length),
                                  rot: atan2(vx, vy) * -180 / .pi, opacity: opacity, tint: colour, blend: p.blend)
            }
            let rot = p.spin ? (time * (r(10) - 0.5) * 360 + r(11) * 360).truncatingRemainder(dividingBy: 360) : 0
            return GameSprite(key: GameSprite.glow, rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: p.spin ? size * 0.6 : size),
                              rot: rot, opacity: opacity, tint: colour, blend: p.blend)
        }
    }

    /// How long a burst of `kind` lasts, at most.
    public static func life(_ kind: String) -> Double { bursts[kind]?.life.1 ?? 0 }

    /// A burst's particles at `time` seconds: thrown from where it began,
    /// each its own way, falling, fading as it goes. None before it began or
    /// after it's over.
    public static func burst(_ spark: GameSpark, time: Double) -> [GameSprite] {
        guard let p = bursts[spark.kind] else { return [] }
        let age = time - spark.start
        guard age >= 0, age <= p.life.1 else { return [] }
        let colour = tint(p.color)
        let k = spark.tall / tall
        return (0..<p.count).compactMap { i in
            func r(_ n: Int) -> Double { noise(spark.seed, i, n) }
            let life = within(p.life, r(0))
            guard age <= life else { return nil }
            var angle = within(p.angle, r(1))
            // Turned about for a thing facing left: dust thrown behind it.
            if spark.flip { angle = .pi - angle }
            let speed = within(p.speed, r(2)) * k
            let x = spark.at.x + cos(angle) * speed * age
            let y = spark.at.y + sin(angle) * speed * age + p.gravity * k * age * age / 2
            let left = 1 - age / life
            let size = within(p.size, r(3)) * k * (0.4 + 0.6 * left)
            return GameSprite(key: GameSprite.glow, rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size), opacity: p.alpha * left, tint: colour, blend: p.blend)
        }
    }

    /// The bursts still going at `time`, of those begun.
    public static func living(_ sparks: [GameSpark], time: Double) -> [GameSpark] {
        sparks.filter { time >= $0.start - 1 && time - $0.start <= life($0.kind) }
    }

    /// What a tick did, as bursts where it happened (Proton's `felt`): dust
    /// as the player jumps and lands, a streak behind a dash, sparks as it's
    /// hurt or rests, sparks on what was struck, a burst where a thing was
    /// beaten. `now` and `before` are the frame and the one before it, in
    /// the same room.
    public static func felt(_ happened: UInt32, now: GameFrame, before: GameFrame?, tick: Int, tall: Double) -> [GameSpark] {
        let time = Double(now.tick) / Double(max(1, tick))
        let feet = now.player
        let mine = Dictionary(now.drawn.map { ($0.who, $0) }, uniquingKeysWith: { a, _ in a })
        let was = Dictionary((before?.drawn ?? []).map { ($0.who, $0) }, uniquingKeysWith: { a, _ in a })
        let facingLeft = mine[0]?.flip ?? false
        func spark(_ kind: String, _ at: CGPoint, _ who: Int, turned: Bool = false) -> GameSpark {
            GameSpark(kind: kind, at: at, start: time, seed: Int32(truncatingIfNeeded: now.tick &* 131 &+ who), flip: turned, tall: tall)
        }
        var out: [GameSpark] = []
        let shot = 1 << 20
        if happened & GameHappened.jumped != 0 { out.append(spark("jump", feet, 0)) }
        if happened & GameHappened.landed != 0 { out += [spark("land", feet, 0), spark("land", feet, 1, turned: true)] }
        if happened & GameHappened.dashed != 0 { out.append(spark("dash", CGPoint(x: feet.x, y: feet.y - 30), 0, turned: !facingLeft)) }
        if happened & GameHappened.hurt != 0 { out.append(spark("hurt", CGPoint(x: feet.x, y: feet.y - 36), 0)) }
        if happened & GameHappened.died != 0 { out.append(spark("kill", CGPoint(x: feet.x, y: feet.y - 36), 0)) }
        if happened & GameHappened.rested != 0 { out.append(spark("rest", CGPoint(x: feet.x, y: feet.y - 20), 0)) }
        if happened & GameHappened.hit != 0 {
            // Sparks on what was struck: whatever has just begun to flash.
            for (who, d) in mine where who > 0 && who < shot && d.flash && !(was[who]?.flash ?? false) {
                out.append(spark("hit", CGPoint(x: d.at.x, y: d.at.y - 20), who))
            }
        }
        if happened & GameHappened.killed != 0 {
            // A burst where what was beaten stood last.
            for (who, d) in was where who > 0 && who < shot && mine[who] == nil {
                out.append(spark("kill", CGPoint(x: d.at.x, y: d.at.y - 20), who))
            }
        }
        return out
    }
}
