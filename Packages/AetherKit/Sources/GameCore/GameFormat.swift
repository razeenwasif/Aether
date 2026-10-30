import CoreGraphics
import Foundation

// A game's files as the Game workspace reads them: the parts of
// proton-game's `format` that are drawn and edited. Proton's writer leaves
// out what is empty, so every field here reads as its default when absent,
// as the Rust types do.

private extension KeyedDecodingContainer {
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

    enum CodingKeys: String, CodingKey { case name, view, input }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, "")
        view = try c.value(.view, GameViewSettings())
        input = try c.value(.input, [:])
    }
}

public struct GameViewSettings: Decodable, Equatable, Sendable {
    public var width: Int = 1920
    public var height: Int = 1080
    /// How far the camera is from the play plane, for parallax.
    public var focal: Double = 1000
    /// `smooth` or `pixel`: how art is scaled.
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
    public var fog: GameFog?

    enum CodingKeys: String, CodingKey { case id, size, camera, planes, collision, entities, spawns, ambience }
    enum CameraKeys: String, CodingKey { case bounds }
    enum AmbienceKeys: String, CodingKey { case fog }
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
        if c.contains(.ambience) {
            fog = try c.nestedContainer(keyedBy: AmbienceKeys.self, forKey: .ambience).decodeIfPresent(GameFog.self, forKey: .fog)
        }
    }

    public var width: Double { Double(size.first ?? 1920) }
    public var height: Double { Double(size.count > 1 ? size[1] : 1080) }

    public func entity(_ id: String) -> GameEntity? { entities.first { $0.id == id } }
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
    public var items: [GameItem]

    enum CodingKeys: String, CodingKey { case id, name, depth, parallax, tint, fog, blend, gameplay, items }
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

/// A thing rooms place: its image, the point of it that stands on the
/// ground, and its body.
public struct GamePrefab: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sprite: String
    public var pivot: [Int]
    public var size: [Int]
    public var health: Int?

    enum CodingKeys: String, CodingKey { case id, name, sprite, pivot, size, health }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        name = try c.value(.name, "")
        sprite = try c.value(.sprite, "")
        pivot = try c.value(.pivot, [0, 0])
        size = try c.value(.size, [32, 32])
        health = try c.decodeIfPresent(Int.self, forKey: .health)
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
