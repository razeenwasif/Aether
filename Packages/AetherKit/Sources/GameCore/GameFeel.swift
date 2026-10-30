import CoreGraphics
import Foundation

// How a game feels and sounds, as arithmetic: the player stretched into a
// jump and squashed by a landing, the screen shaken by a blow, the sounds a
// tick plays and the music a room plays. Proton's `game-play.js` (`felt`,
// the squash and the shake in `draw`) and `game-audio.js` (`soundsFor`,
// `musicFor`), ported. None of it touches the run: a run felt and heard is
// the same run as one that isn't.

/// `game.json`'s `feel`: how far the camera leads (the sim's), how hard a
/// blow shakes the screen, how much a body squashes and stretches.
public struct GameFeel: Decodable, Equatable, Sendable {
    public var lookahead: Int = 96
    /// 0 to 1.
    public var shake: Double = 0.5
    /// 0 to 1.
    public var squash: Double = 0.5

    public init(lookahead: Int = 96, shake: Double = 0.5, squash: Double = 0.5) {
        self.lookahead = lookahead
        self.shake = shake
        self.squash = squash
    }

    enum CodingKeys: String, CodingKey { case lookahead, shake, squash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lookahead = try c.value(.lookahead, 96)
        shake = try c.value(.shake, 0.5)
        squash = try c.value(.squash, 0.5)
    }
}

/// `game.json`'s `audio`: how loud sounds and music are, and the file each
/// event or cue plays.
public struct GameAudioSettings: Decodable, Equatable, Sendable {
    /// 0 to 1.
    public var effects: Double = 0.8
    /// 0 to 1.
    public var music: Double = 0.6
    public var sounds: [String: String] = [:]

    public init(effects: Double = 0.8, music: Double = 0.6, sounds: [String: String] = [:]) {
        self.effects = effects
        self.music = music
        self.sounds = sounds
    }

    enum CodingKeys: String, CodingKey { case effects, music, sounds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effects = try c.value(.effects, 0.8)
        music = try c.value(.music, 0.6)
        sounds = try c.value(.sounds, [:])
    }
}

/// `world.json` as far as sound goes: each area's music, and each room's area.
public struct GameWorldMap: Decodable, Equatable, Sendable {
    public var areas: [Area]
    public var rooms: [Room]

    public struct Area: Decodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var music: String?

        enum CodingKeys: String, CodingKey { case id, name, music }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.value(.id, "")
            name = try c.value(.name, "")
            music = try c.decodeIfPresent(String.self, forKey: .music)
        }
    }

    public struct Room: Decodable, Equatable, Sendable {
        public var id: String
        public var area: String

        enum CodingKeys: String, CodingKey { case id, area }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.value(.id, "")
            area = try c.value(.area, "")
        }
    }

    public init(areas: [Area] = [], rooms: [Room] = []) {
        self.areas = areas
        self.rooms = rooms
    }

    enum CodingKeys: String, CodingKey { case areas, rooms }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areas = try c.value(.areas, [])
        rooms = try c.value(.rooms, [])
    }

    /// The music a room plays: its area's, or none.
    public func music(_ room: String) -> String? {
        let area = rooms.first { $0.id == room }?.area
        return areas.first { $0.id == area }?.music.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The area a room is in.
    public func area(of room: String) -> Area? {
        let area = rooms.first { $0.id == room }?.area
        return areas.first { $0.id == area }
    }
}

public enum GameSound {
    /// A tick's bits by the names `game.json` gives sounds (proton-game's
    /// `SOUND_EVENTS`).
    public static let events: [(bit: UInt32, name: String)] = [
        (1, "jump"), (2, "land"), (4, "dash"), (8, "hurt"), (16, "enter"), (32, "gain"),
        (128, "swing"), (256, "hit"), (512, "kill"), (1024, "die"), (2048, "rest"), (4096, "flag"), (8192, "shot"),
    ]

    /// The events a sound can be put to, and what each is, in the order
    /// proton-game lists them.
    public static let described: [(name: String, what: String)] = [
        ("jump", "the player jumps"), ("land", "the player lands"), ("dash", "the player dashes"), ("swing", "the player swings"),
        ("hit", "a swing lands"), ("kill", "something is beaten"), ("hurt", "the player is hurt"), ("die", "the player dies"),
        ("shot", "a turret shoots"), ("rest", "the player rests at a bench"), ("gain", "an ability is picked up"),
        ("flag", "a flag is set"), ("enter", "a room is entered"),
    ]

    /// The files a tick plays: each event it said and each cue that has a
    /// sound, once each. A death is the death's sound alone, not the hurt's
    /// under it too.
    public static func files(_ bits: UInt32, cues: [String], sounds: [String: String]) -> [String] {
        let said = events.filter { bits & $0.bit != 0 }.map(\.name)
        let names = said.contains("die") && sounds["die"] != nil ? said.filter { $0 != "hurt" } : said
        var out: [String] = []
        for name in names + cues {
            if let file = sounds[name], !file.isEmpty, !out.contains(file) { out.append(file) }
        }
        return out
    }
}

/// The player's last squash or stretch and the screen's last shake, each
/// from the tick it began at, eased back to nothing.
public struct GameJolt: Equatable, Sendable {
    /// Ticks a squash or stretch, and a shake, take to settle.
    public static let squashTicks = 10.0
    public static let shakeTicks = 14.0

    public var squash: (tick: Int, stretch: Bool)?
    public var shake: (tick: Int, amount: Double)?

    public init() {}

    public static func == (a: GameJolt, b: GameJolt) -> Bool {
        a.squash?.tick == b.squash?.tick && a.squash?.stretch == b.squash?.stretch && a.shake?.tick == b.shake?.tick && a.shake?.amount == b.shake?.amount
    }

    /// What a tick did, as a jolt: a jump stretches, a landing squashes, a
    /// hurt or a death shakes hard, a blow landed less, a thing beaten more.
    public mutating func felt(_ happened: UInt32, tick: Int) {
        if happened & GameHappened.jumped != 0 { squash = (tick, true) }
        if happened & GameHappened.landed != 0 { squash = (tick, false) }
        if happened & (GameHappened.hurt | GameHappened.died) != 0 { shake = (tick, 1) }
        func harder(_ amount: Double) -> Double {
            guard let shake, Double(tick - shake.tick) < Self.shakeTicks else { return amount }
            return max(shake.amount, amount)
        }
        if happened & GameHappened.hit != 0 { shake = (tick, harder(0.35)) }
        if happened & GameHappened.killed != 0 { shake = (tick, harder(0.6)) }
    }

    /// How the player is squashed or stretched about its feet at `tick`
    /// (fractions and all), by how much the game says; none when settled.
    public func scale(at tick: Double, feel: GameFeel) -> CGSize? {
        guard let squash, feel.squash > 0 else { return nil }
        let age = tick - Double(squash.tick)
        guard age >= 0, age < Self.squashTicks else { return nil }
        let k = (1 - age / Self.squashTicks) * feel.squash
        return squash.stretch ? CGSize(width: 1 - 0.25 * k, height: 1 + 0.3 * k) : CGSize(width: 1 + 0.3 * k, height: 1 - 0.25 * k)
    }

    /// How far the camera is jolted at `tick` (fractions and all): a jolt a
    /// whole tick, fading, by how hard the game says; none when settled.
    public func offset(at tick: Double, feel: GameFeel) -> CGVector {
        guard let shake, feel.shake > 0 else { return .zero }
        let age = tick - Double(shake.tick)
        guard age >= 0, age < Self.shakeTicks else { return .zero }
        let amp = shake.amount * feel.shake * 12 * (1 - age / Self.shakeTicks)
        let t = Int32(truncatingIfNeeded: Int(tick.rounded(.down)))
        return CGVector(dx: (GameFX.noise(t, 1, 0) - 0.5) * 2 * amp, dy: (GameFX.noise(t, 2, 0) - 0.5) * 2 * amp)
    }
}
