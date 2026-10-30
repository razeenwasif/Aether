import CoreGraphics
import DiffuseBridge
import Foundation

/// What a run's world says the window needs: ticks a second, the camera's
/// view, the rooms' ids, the images its frames name, where it starts.
public struct GameRunInfo: Decodable, Sendable {
    public var tick: Int
    public var view: [Int]
    public var rooms: [String]
    public var sprites: [String]
    public var start: Start
    public var health: Int

    public struct Start: Decodable, Sendable {
        public var room: Int
        public var at: [Int]
    }
}

/// One thing a frame draws.
public struct GameDrawn: Equatable, Sendable {
    /// The image, by its place in the world's sprites; -1 a shot with none.
    public var sprite: Int
    /// Where its pivot stands, in room pixels.
    public var at: CGPoint
    public var pivot: CGPoint
    public var flip: Bool
    /// Just hurt: drawn white.
    public var flash: Bool
    /// Spared for now: drawn faint.
    public var blink: Bool
    /// 0 the player, a thing one more than its place in the room, a shot
    /// `1 << 20` and more.
    public var who: Int
}

/// A frame of a run, as the runtime lays it out (proton-game-runtime's
/// header and records, word for word).
public struct GameFrame: Equatable, Sendable {
    public static let header = 16
    public static let record = 9

    public let words: [Int32]

    public init(_ words: [Int32]) { self.words = words }

    private func word(_ i: Int) -> Int { i < words.count ? Int(words[i]) : 0 }
    public var tick: Int { word(1) }
    public var room: Int { word(2) }
    /// The camera's middle, in room pixels.
    public var camera: CGPoint { CGPoint(x: Double(word(3)) / 256, y: Double(word(4)) / 256) }
    /// How far through a door, 0 none, else 1–24.
    public var door: Int { word(5) }
    public var deaths: Int { word(6) }
    public var player: CGPoint { CGPoint(x: Double(word(9)) / 256, y: Double(word(10)) / 256) }
    public var health: Int { word(12) }
    public var mostHealth: Int { word(13) }
    public var beaten: Int { word(14) }

    public var drawn: [GameDrawn] {
        (0..<max(0, word(8))).compactMap { i -> GameDrawn? in
            let o = Self.header + i * Self.record
            guard o + Self.record <= words.count else { return nil }
            let look = word(o + 5)
            return GameDrawn(sprite: word(o), at: CGPoint(x: word(o + 1), y: word(o + 2)), pivot: CGPoint(x: word(o + 3), y: word(o + 4)),
                             flip: look & 1 != 0, flash: look & 2 != 0, blink: look & 4 != 0, who: word(o + 8))
        }
    }
}

/// Play: a run stepped at the game's tick on a fixed clock, so a frame of
/// the screen may run several ticks or none and the run is the same run at
/// any frame rate. The input held each tick is kept as it is played, and
/// can be replayed on a fresh run of the same world to see that it ends in
/// the same place.
@MainActor
public final class GamePlayer {
    public let run: GameRun
    public let info: GameRunInfo
    /// The input held now: a bit an action.
    public var held: UInt32 = 0
    /// The newest frame, and the one before it, to ease between.
    public private(set) var now: GameFrame
    public private(set) var before: GameFrame?
    /// What happened since it was last taken: `happened` bits.
    public private(set) var happened: UInt32 = 0
    /// The input held, tick by tick, as runs of the same.
    public private(set) var recording: [(input: UInt32, ticks: UInt32)] = []
    private let world: String
    private let start: (room: UInt32, x: Int32, y: Int32)
    private var left: Double = 0

    /// A run of `run`'s world from its start.
    public init(_ run: GameRun) throws {
        self.run = run
        info = try JSONDecoder().decode(GameRunInfo.self, from: Data(run.info().utf8))
        world = run.world()
        try run.startAtStart()
        start = (UInt32(info.start.room), Int32(info.start.at.first ?? 0), Int32(info.start.at.count > 1 ? info.start.at[1] : 0))
        now = GameFrame(run.frame())
    }

    public var seconds: Double { 1 / Double(max(1, info.tick)) }

    /// One tick with the input held.
    public func step() {
        happened |= run.step(input: held)
        if let last = recording.last, last.input == held {
            recording[recording.count - 1].ticks += 1
        } else {
            recording.append((held, 1))
        }
        before = now
        now = GameFrame(run.frame())
    }

    /// The clock moved on `elapsed` seconds: as many ticks as fit (a quarter
    /// second at most, after a stall). How far towards the next tick it is,
    /// 0–1, for easing.
    @discardableResult
    public func advance(by elapsed: Double) -> Double {
        left += min(0.25, max(0, elapsed))
        while left >= seconds {
            step()
            left -= seconds
        }
        return left / seconds
    }

    /// What happened since last asked, and forget it.
    public func takeHappened() -> UInt32 {
        defer { happened = 0 }
        return happened
    }

    /// The input played, replayed on a fresh run of the same world from the
    /// same start: whether it ends in the same state, and that state's hash.
    public func replayCheck() throws -> (same: Bool, ticks: Int, hash: UInt64) {
        let again = try GameRun.fromWorld(world: world)
        try again.start(room: start.room, x: start.x, y: start.y, abilities: 0)
        var ticks = 0
        for (input, n) in recording {
            for _ in 0..<n { _ = again.step(input: input) }
            ticks += Int(n)
        }
        return (again.hash() == run.hash(), ticks, run.hash())
    }

    /// The bit each action is, by `game.json`'s names (proton-game's
    /// `sim::input`).
    public static let actions: [String: UInt32] = ["left": 1, "right": 2, "up": 4, "down": 8, "jump": 16, "attack": 32, "dash": 64]

    /// Each key's bits, by Proton's key names, from a game's input map (the
    /// defaults where it says nothing).
    public static func keys(_ input: [String: [String]]) -> [String: UInt32] {
        let defaults: [String: [String]] = [
            "left": ["ArrowLeft", "KeyA"], "right": ["ArrowRight", "KeyD"], "up": ["ArrowUp", "KeyW"], "down": ["ArrowDown", "KeyS"],
            "jump": ["KeyZ", "Space"], "attack": ["KeyX"], "dash": ["KeyC", "ShiftLeft"],
        ]
        var out: [String: UInt32] = [:]
        for (action, bit) in actions {
            for key in input[action] ?? defaults[action] ?? [] where !key.hasPrefix("pad:") {
                out[key, default: 0] |= bit
            }
        }
        return out
    }
}
