import CoreGraphics
import Foundation

// A game's files as the Game workspace reads them: the parts of
// proton-game's `format` that are drawn and edited. Proton's writer leaves
// out what is empty, so every field here reads as its default when absent,
// as the Rust types do.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

/// `game.json`: what the workspace needs of it.
public struct GameFile: Decodable, Equatable, Sendable {
    public var name: String
    public var view: GameViewSettings
    /// Each action's keys, by Proton's names (`ArrowLeft`, `KeyZ`, `pad:a`).
    public var input: [String: [String]]
    /// The abilities a player can gain, by id.
    public var abilities: [String]
    /// What's done to the whole picture after it's drawn.
    public var post: GamePost
    /// How it feels to hold, and what it sounds like.
    public var feel: GameFeel
    public var audio: GameAudioSettings
    /// What kind of game it is (`metroidvania`, `isometric`, …): an
    /// isometric one walks on the ground, seen from above at an angle.
    public var niche: String
    /// How far up the screen moving away covers, of moving across, on an
    /// isometric game's ground.
    public var groundDepth: Double

    /// Whether it walks on the ground, seen from above at an angle.
    public var isIsometric: Bool { niche == "isometric" }

    private struct Ability: Decodable { var id: String }
    private struct Ground: Decodable { var depth: Double? }
    enum CodingKeys: String, CodingKey { case name, view, input, abilities, post, feel, audio, niche, ground }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, "")
        view = try c.value(.view, GameViewSettings())
        input = try c.value(.input, [:])
        abilities = try c.value(.abilities, [Ability]()).map(\.id)
        post = try c.value(.post, GamePost())
        feel = try c.value(.feel, GameFeel())
        audio = try c.value(.audio, GameAudioSettings())
        niche = try c.value(.niche, "metroidvania")
        groundDepth = try c.decodeIfPresent(Ground.self, forKey: .ground)?.depth ?? 0.5
    }
}

/// The finish on the whole picture: bright light spilling (bloom), a colour
/// grade from a lookup table, and corners darkened. Proton's defaults.
public struct GamePost: Decodable, Equatable, Sendable {
    /// How much bright light spills, 0 to 1.
    public var bloom: Double = 0.25
    /// A lookup table's image (n² wide, n tall), when there is one.
    public var grade: String?
    /// How dark the corners go, 0 to 1.
    public var vignette: Double = 0.3

    public init(bloom: Double = 0.25, grade: String? = nil, vignette: Double = 0.3) {
        self.bloom = bloom
        self.grade = grade
        self.vignette = vignette
    }
    enum CodingKeys: String, CodingKey { case bloom, grade, vignette }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bloom = try c.value(.bloom, 0.25)
        grade = try c.decodeIfPresent(String.self, forKey: .grade)
        vignette = try c.value(.vignette, 0.3)
    }
}

public struct GameViewSettings: Decodable, Equatable, Sendable {
    public var width: Int = 1920
    public var height: Int = 1080
    /// How far the camera is from the play plane, for parallax.
    public var focal: Double = 1000
    /// `smooth` for painted art, `nearest` for pixel art.
    public var filter: String = "smooth"

    public init() {}
    enum CodingKeys: String, CodingKey { case width, height, focal, filter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.value(.width, 1920)
        height = try c.value(.height, 1080)
        focal = try c.value(.focal, 1000)
        filter = try c.value(.filter, "smooth")
    }

    /// Pixel art: sampled nearest, and in Play drawn at the game's own
    /// resolution, then scaled up by whole numbers.
    public var pixelArt: Bool { filter == "nearest" }
}

/// A room: planes of art back to front, collision, the things in it.
public struct GameRoom: Decodable, Equatable, Sendable {
    public var id: String
    public var size: [Int]
    /// What the camera may show, `[x, y, w, h]`; the room when absent.
    public var bounds: [Int]?
    public var planes: [GamePlane]
    public var collision: [GameShape]
    public var entities: [GameEntity]
    public var spawns: [GameSpawn]
    public var lights: [GameLight]
    public var fog: GameFog?
    /// The light where no light falls on a lit plane, `#rrggbb`; white, the
    /// art as painted, when not said.
    public var ambient: String?
    /// What hangs in its air, a plane each.
    public var particles: [GameEmitter] = []

    enum CodingKeys: String, CodingKey { case id, size, camera, planes, collision, entities, spawns, lights, ambience }
    enum CameraKeys: String, CodingKey { case bounds }
    enum AmbienceKeys: String, CodingKey { case fog, ambient, particles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        size = try c.value(.size, [1920, 1080])
        if c.contains(.camera) {
            bounds = try c.nestedContainer(keyedBy: CameraKeys.self, forKey: .camera).decodeIfPresent([Int].self, forKey: .bounds)
        }
        planes = try c.value(.planes, [])
        collision = try c.value(.collision, [])
        entities = try c.value(.entities, [])
        spawns = try c.value(.spawns, [])
        lights = try c.value(.lights, [])
        if c.contains(.ambience) {
            let ambience = try c.nestedContainer(keyedBy: AmbienceKeys.self, forKey: .ambience)
            fog = try ambience.decodeIfPresent(GameFog.self, forKey: .fog)
            ambient = try ambience.decodeIfPresent(String.self, forKey: .ambient)
            particles = try ambience.decodeIfPresent([GameEmitter].self, forKey: .particles) ?? []
        }
    }

    public var width: Double { Double(size.first ?? 1920) }
    public var height: Double { Double(size.count > 1 ? size[1] : 1080) }

    public func entity(_ id: String) -> GameEntity? { entities.first { $0.id == id } }
    public func shape(_ id: String) -> GameShape? { collision.first { $0.id == id } }
    public func light(_ id: String) -> GameLight? { lights.first { $0.id == id } }
    public func spawn(_ id: String) -> GameSpawn? { spawns.first { $0.id == id } }
    /// The plane the game is played on, which collision, things and lights
    /// belong to.
    public var playPlane: GamePlane? { planes.first(where: \.gameplay) }

    /// An id not yet taken in the room: `stem_1`, `stem_2`…
    public func freshID(_ stem: String) -> String {
        let taken = Set(collision.map(\.id) + entities.map(\.id) + lights.map(\.id) + spawns.map(\.id))
        var n = 1
        while taken.contains("\(stem)_\(n)") { n += 1 }
        return "\(stem)_\(n)"
    }
}

/// A sheet of art at a depth behind (positive) or before (negative) the play
/// plane.
public struct GamePlane: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var depth: Double
    public var parallax: Double?
    public var tint: String?
    public var fog: Double
    public var blend: String
    public var gameplay: Bool
    /// Whether the room's lights fall on it.
    public var lit: Bool
    public var items: [GameItem]

    enum CodingKeys: String, CodingKey { case id, name, depth, parallax, tint, fog, blend, gameplay, lit, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        depth = try c.value(.depth, 0)
        parallax = try c.decodeIfPresent(Double.self, forKey: .parallax)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        fog = try c.value(.fog, 0)
        blend = try c.value(.blend, "normal")
        gameplay = try c.value(.gameplay, false)
        lit = try c.value(.lit, false)
        items = try c.value(.items, [])
    }
}

/// An image placed on a plane, its top-left at `at`.
public struct GameItem: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var image: String
    public var at: [Int]
    public var scale: Double
    public var rot: Double
    public var flip: Bool
    public var opacity: Double
    public var blend: String

    enum CodingKeys: String, CodingKey { case id, image, at, scale, rot, flip, opacity, blend }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        image = try c.value(.image, "")
        at = try c.value(.at, [0, 0])
        scale = try c.value(.scale, 1)
        rot = try c.value(.rot, 0)
        flip = try c.value(.flip, false)
        opacity = try c.value(.opacity, 1)
        blend = try c.value(.blend, "normal")
    }
}

/// Something solid, drawn as a line through points.
public struct GameShape: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    /// `solid`, `oneway`, `hazard` or `nowall`.
    public var kind: String
    public var closed: Bool
    public var points: [[Int]]

    enum CodingKeys: String, CodingKey { case id, kind, closed, points }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        kind = try c.value(.kind, "solid")
        closed = try c.value(.closed, false)
        points = try c.value(.points, [])
    }
}

/// A thing in a room: a built-in kind (`transition`, `save_point`,
/// `ability_gate`, `ability_pickup`, `trigger`) or a prefab of the game's.
public struct GameEntity: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var prefab: String
    /// Where it stands, for a thing that stands somewhere: its feet.
    public var at: [Int]?
    /// The area it covers, `[x, y, w, h]`, for a thing that covers one.
    public var rect: [Int]?
    /// Where a transition leads: a room and a spawn there.
    public var to: GameExit?
    public var requires: [String]
    public var grants: String?

    enum CodingKeys: String, CodingKey { case id, prefab, at, rect, to, requires, grants }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        prefab = try c.value(.prefab, "")
        at = try c.decodeIfPresent([Int].self, forKey: .at)
        rect = try c.decodeIfPresent([Int].self, forKey: .rect)
        to = try c.decodeIfPresent(GameExit.self, forKey: .to)
        requires = try c.value(.requires, [])
        grants = try c.decodeIfPresent(String.self, forKey: .grants)
    }

    /// The kinds every game has, which no prefab file makes.
    public static let builtIn = ["transition", "save_point", "ability_gate", "ability_pickup", "trigger"]
}

public struct GameExit: Decodable, Equatable, Sendable {
    public var room: String
    public var entry: String

    enum CodingKeys: String, CodingKey { case room, entry }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = try c.value(.room, "")
        entry = try c.value(.entry, "")
    }
}

/// A light standing on a plane: its reach, its colour and how bright, how
/// it wavers, and the halo round it in the air.
public struct GameLight: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var plane: String
    public var at: [Int]
    public var radius: Int
    public var color: String
    public var intensity: Double
    public var flicker: Double
    public var glow: Double
    /// How far in front of the planes it hangs: low, it rakes across what a
    /// normal map raises; high, it falls flat on it.
    public var height: Double

    enum CodingKeys: String, CodingKey { case id, plane, at, radius, color, intensity, flicker, glow, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        plane = try c.value(.plane, "")
        at = try c.value(.at, [0, 0])
        radius = try c.value(.radius, 400)
        color = try c.value(.color, "#ffd9a0")
        intensity = try c.value(.intensity, 1)
        flicker = try c.value(.flicker, 0)
        glow = try c.value(.glow, 0)
        height = try c.value(.height, 80)
    }
}

/// Where a player arrives: a run's start, or the far side of a door.
public struct GameSpawn: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: [Int]
}

/// The room's fog: none nearer than `near`, `amount` of `color` at `far`.
public struct GameFog: Decodable, Equatable, Sendable {
    public var color: String
    public var near: Double
    public var far: Double
    public var amount: Double

    enum CodingKeys: String, CodingKey { case color, near, far, amount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.value(.color, "#000000")
        near = try c.value(.near, 0)
        far = try c.value(.far, 1)
        amount = try c.value(.amount, 0)
    }
}

/// An image cut up (`.img.json`): a painted backdrop can be larger than a
/// texture may be, so it's kept as pieces, empty ones dropped; its normal
/// map, when it has one, is cut the same way.
public struct GameImageParts: Decodable, Equatable, Sendable {
    public var size: [Int]
    public var chunks: [Chunk]
    public var normal: [Chunk]

    public struct Chunk: Decodable, Equatable, Sendable {
        public var file: String
        public var at: [Int]
        public var size: [Int]

        enum CodingKeys: String, CodingKey { case file, at, size }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.value(.file, "")
            at = try c.value(.at, [0, 0])
            size = try c.value(.size, [0, 0])
        }
    }

    enum CodingKeys: String, CodingKey { case size, chunks, normal }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.value(.size, [0, 0])
        chunks = try c.value(.chunks, [])
        normal = try c.value(.normal, [])
    }
}

/// A thing rooms place: its image, the point of it that stands on the
/// ground, and its body.
public struct GamePrefab: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sprite: String
    public var pivot: [Int]
    public var size: [Int]
    public var health: Int?
    /// For an animated sprite, the clip a state plays where it isn't the
    /// clip of the state's own name.
    public var clips: [String: String]

    enum CodingKeys: String, CodingKey { case id, name, sprite, pivot, size, health, clips }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        sprite = try c.value(.sprite, "")
        pivot = try c.value(.pivot, [0, 0])
        size = try c.value(.size, [32, 32])
        health = try c.decodeIfPresent(Int.self, forKey: .health)
        clips = try c.value(.clips, [:])
    }

    public var animated: Bool { sprite.hasSuffix(".anim.json") }
}

/// An animation (`.anim.json`): frames cut from sheets, placed on the
/// sprite's canvas, in named clips.
public struct GameAnim: Decodable, Equatable, Sendable {
    public var size: [Int]
    public var sheets: [String]
    public var frames: [Frame]
    public var clips: [Clip]

    public struct Frame: Decodable, Equatable, Sendable {
        public var sheet: Int
        /// Left, top, width and height on the sheet.
        public var rect: [Int]
        /// Where the rectangle's top-left sits on the sprite's canvas.
        public var offset: [Int]
        public var ms: Int

        enum CodingKeys: String, CodingKey { case sheet, rect, offset, ms }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sheet = try c.value(.sheet, 0)
            rect = try c.value(.rect, [0, 0, 0, 0])
            offset = try c.value(.offset, [0, 0])
            ms = try c.value(.ms, 100)
        }
    }

    public struct Clip: Decodable, Equatable, Sendable {
        public var name: String
        public var from: Int
        public var to: Int
        public var direction: String

        enum CodingKeys: String, CodingKey { case name, from, to, direction }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            from = try c.value(.from, 0)
            to = try c.value(.to, 0)
            direction = try c.value(.direction, "forward")
        }
    }

    enum CodingKeys: String, CodingKey { case size, sheets, frames, clips }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.value(.size, [0, 0])
        sheets = try c.value(.sheets, [])
        frames = try c.value(.frames, [])
        clips = try c.value(.clips, [])
    }

    /// The frame a thing standing still shows: its idle clip's first — the
    /// clip a prefab names for idle, else one called idle, else the first.
    public func restingFrame(_ chosen: [String: String] = [:]) -> Int {
        let clip = clips.first { $0.name == chosen["idle"] } ?? clips.first { $0.name.lowercased() == "idle" } ?? clips.first
        guard let clip else { return 0 }
        return clip.direction == "reverse" || clip.direction == "pingPongReverse" ? clip.to : clip.from
    }
}

/// The game open, as the core describes everything but its rooms.
public struct GameProjectView: Decodable, Equatable, Sendable {
    public var path: String
    public var game: GameFile
    public var prefabs: [GamePrefab]
    public var rooms: [Row]
    public var unsaved: [String]
    public var problems: [String]
    /// The map, as far as sound goes: each area's music.
    public var world: GameWorldMap

    public struct Row: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var size: [Int]
        public var dirty: Bool
        public var canUndo: Bool
        public var canRedo: Bool
    }

    public func prefab(_ id: String) -> GamePrefab? { prefabs.first { $0.id == id } }
}

/// A game found in the games folder, for the home page.
public struct GameFound: Decodable, Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var rooms: Int
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// The parallax arithmetic Proton's window did (`game-scene.js`), for the
/// editor's camera and Play's alike.
public enum GameScene {
    /// How fast a plane moves against the play plane: its own `parallax`, or
    /// `focal / (focal + depth)`. At or behind the camera it races past.
    public static func factor(_ plane: GamePlane, focal: Double) -> Double {
        if let parallax = plane.parallax { return parallax }
        let far = focal + plane.depth
        return far <= 1 ? 1000 : focal / far
    }

    /// The game camera's top-left when centred at `center`, held inside the
    /// room's camera bounds (centred in them when the view is the larger).
    public static func corner(_ room: GameRoom, view: CGSize, center: CGPoint) -> CGPoint {
        let b = room.bounds ?? [0, 0, Int(room.width), Int(room.height)]
        func hold(_ at: Double, _ lo: Double, _ span: Double, _ size: Double) -> Double {
            span <= size ? lo + (span - size) / 2 : max(lo, min(lo + span - size, at - size / 2))
        }
        return CGPoint(x: hold(center.x, Double(b[0]), Double(b[2]), view.width), y: hold(center.y, Double(b[1]), Double(b[3]), view.height))
    }

    /// How far a plane's own pixels are shifted at a factor and a corner.
    public static func shift(_ factor: Double, corner: CGPoint) -> CGPoint {
        CGPoint(x: corner.x * (1 - factor), y: corner.y * (1 - factor))
    }

    /// Where an image stands on its feet: its frame in the room, flipped
    /// about the feet so it turns where it stands (Proton's `standing`).
    public static func stillFrame(size: CGSize, at: CGPoint, pivot: CGPoint, flip: Bool) -> CGRect {
        let x = flip ? at.x - (size.width - pivot.x) : at.x - pivot.x
        return CGRect(x: x, y: at.y - pivot.y, width: size.width, height: size.height)
    }

    /// Where an animation's frame stands on its feet: the part of its sheet
    /// placed where it sits on the sprite's canvas, flipped about the feet
    /// (Proton's `frameSprite`).
    public static func animFrame(_ frame: GameAnim.Frame, at: CGPoint, pivot: CGPoint, flip: Bool) -> CGRect {
        let (w, h) = (Double(frame.rect.count > 2 ? frame.rect[2] : 0), Double(frame.rect.count > 3 ? frame.rect[3] : 0))
        let ox = Double(frame.offset.first ?? 0), oy = Double(frame.offset.count > 1 ? frame.offset[1] : 0)
        let x = flip ? at.x + pivot.x - ox - w : at.x - pivot.x + ox
        return CGRect(x: x, y: at.y - pivot.y + oy, width: w, height: h)
    }

    /// How far a point is from a segment.
    public static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// A plane's haze, `(r, g, b, amount)`: its own tint by its fog, or the
    /// room's fog by the plane's depth. None on the play plane.
    public static func haze(_ room: GameRoom, _ plane: GamePlane) -> (Double, Double, Double, Double) {
        if let tint = plane.tint, plane.fog > 0 {
            let (r, g, b) = rgb(tint)
            return (r, g, b, min(1, plane.fog))
        }
        guard let fog = room.fog, !plane.gameplay else { return (0, 0, 0, 0) }
        let t = max(0, min(1, (plane.depth - fog.near) / max(1, fog.far - fog.near))) * fog.amount
        let (r, g, b) = rgb(fog.color)
        return t > 0 ? (r, g, b, min(1, t)) : (0, 0, 0, 0)
    }

    /// `#rrggbb` as 0–1 channels.
    public static func rgb(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let n = Int(digits, radix: 16) else { return (0, 0, 0) }
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }
}
