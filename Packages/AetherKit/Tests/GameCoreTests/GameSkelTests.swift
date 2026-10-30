import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GameCore
@testable import GameUI

/// Skeletons posed against what's worked out by hand — Proton's
/// `game-skel.test.mjs`, ported — a skeleton as proton-game writes it, and a
/// skinned part on the GPU; then feel and sound.
@MainActor
struct GameSkelTests {
    private func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 } }
    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }

    private let hero = """
    {"format": 1, "source": "hero_ske.json", "atlas": "hero_tex.png", "atlasSize": [64, 32], "fps": 24,
     "bones": [{"name": "root", "parent": null, "at": [0, 0]}, {"name": "body", "parent": 0, "at": [0, -20]}, {"name": "arm", "parent": 1, "at": [4, -6], "rot": 90}],
     "slots": [{"name": "arm", "bone": 2, "parts": [{"name": "arm"}, {"name": "fist"}]}],
     "clips": [
       {"name": "wave", "frames": 10,
        "bones": [{"bone": 2, "turned": [{"frame": 0, "value": [0, 0], "ease": {"kind": "linear"}}, {"frame": 10, "value": [90, 0], "ease": {"kind": "linear"}}]},
                  {"bone": 1, "moved": [{"frame": 0, "value": [0, 0], "ease": {"kind": "step"}}, {"frame": 4, "value": [0, -4], "ease": {"kind": "linear"}}],
                   "scaled": [{"frame": 0, "value": [2, 1], "ease": {"kind": "linear"}}]}],
        "slots": [{"slot": 0, "shown": [[0, 0], [6, 1]], "color": [{"frame": 0, "color": [1, 1, 1, 1], "ease": {"kind": "linear"}}, {"frame": 10, "color": [1, 1, 1, 0], "ease": {"kind": "linear"}}]}]},
       {"name": "Idle", "frames": 4, "repeat": 1}],
     "boxes": [{"name": "hitbox", "kind": "hit", "slot": 0, "part": 1, "bone": 2, "points": [[0, 0], [10, 0]]}]}
    """

    private func skel(_ text: String) throws -> GameSkel { try JSONDecoder().decode(GameSkel.self, from: Data(text.utf8)) }

    @Test func everyEaseDragonBonesHasHalfWay() {
        #expect(GameEase.step.eased(0.5) == 0)
        #expect(GameEase.linear.eased(0.5) == 0.5)
        #expect(GameEase.easeIn(1).eased(0.5) == 0.25)
        #expect(GameEase.easeOut(1).eased(0.5) == 0.75)
        #expect(GameEase.easeOut(0.5).eased(0.5) == 0.625)
        #expect(abs(GameEase.inOut(1).eased(0.5) - 0.5) < 1e-12)
        #expect(abs(GameEase.inOut(1).eased(0.25) - 0.5 * (1 - cos(Double.pi / 4))) < 1e-12)
        #expect(abs(GameEase.bezier([0.42, 0, 0.58, 1]).eased(0.5) - 0.5) < 1e-6)
        #expect(GameEase.bezier([0.42, 0, 0.58, 1]).eased(0.2) < 0.2, "an ease-in-out Bézier is slow at first")
    }

    @Test func aBoneTurnedOnItsParentAndPointsCarriedByOneBoneAndByTwo() throws {
        let s = try skel(hero)
        #expect(near(s.pose(nil, 0).bones[2], [0, 1, -1, 0, 4, -26]), "the arm at rest")
        // Half through the wave: the arm turned 45 more; the body stepped,
        // not yet moved, and twice as wide.
        let half = s.pose(0, 5)
        let r = 0.5.squareRoot()
        #expect(near(half.bones[1], [2, 0, 0, 1, 0, -24]), "the body moved 4 up by frame 5, and scaled: \(half.bones[1])")
        #expect(near(half.bones[2], [-2 * r, r, -2 * r, -r, 8, -30]), "the arm, turned to 135 on the body: \(half.bones[2])")
        #expect(near(half.skin([.init(bone: 2, weight: 1, at: [10, 0])]), CGPoint(x: 8 - 20 * r, y: -30 + 10 * r)), "a point on the arm")
        #expect(near(half.skin([.init(bone: 1, weight: 0.5, at: [0, 0]), .init(bone: 2, weight: 0.5, at: [10, 0])]),
                     CGPoint(x: (0 + 8 - 20 * r) / 2, y: (-24 - 30 + 10 * r) / 2)), "a point the body and the arm carry half each")
        // The slot's part from frame 6, its colour fading.
        #expect(s.pose(0, 5).shown[0] == 0 && s.pose(0, 6).shown[0] == 1)
        #expect(near(s.pose(0, 5).colors[0], [1, 1, 1, 0.5]), "the colour half way")
        // Past the last key, its.
        #expect(near(Array(s.pose(0, 12).bones[2].prefix(4)), Array(s.pose(0, 10).bones[2].prefix(4))), "past the end")
    }

    @Test func aRunsTicksBackToAClipsFramesAndBoxesWhereTheirBonesAre() throws {
        let s = try skel(hero)
        #expect(s.clipTicks(60) == [0...24, 25...34])
        let idle = s.moment(60, 30)
        #expect(idle.clip == 1 && idle.frame == 2)
        let wave = s.moment(60, 12)
        #expect(wave.clip == 0 && abs(wave.frame - 4.8) < 1e-9, "tick 12 is \(wave)")
        let rest = s.moment(60, nil)
        #expect(rest.clip == 1 && rest.frame == 0, "at rest: the clip called idle")
        #expect(s.restingClip(["idle": "wave"]) == 0)
        #expect(s.boxes(s.pose(0, 0)).isEmpty, "a box is shown only with its part")
        let hit = try #require(s.boxes(s.pose(0, 6)).first)
        #expect(hit.kind == "hit" && near(hit.points[1], s.pose(0, 6).skin([.init(bone: 2, weight: 1, at: [10, 0])])), "its corner, carried by the arm")
    }

    @Test func aSkeletonAsProtonGameWritesItIsPosedWhole() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../cores/proton-game/tests/fixtures/game-skel.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let text = try #require(fixture?["skel"] as? String)
        #expect(text.contains("\"clips\"") && !text.contains("\"cues\":[]"), "the written skeleton leaves its empty lists out, or this tests nothing")
        let s = try skel(text)
        for clip in s.clips.indices {
            for f in [0, 3.5, Double(s.clips[clip].frames)] {
                #expect(s.pose(clip, f).bones.allSatisfy { $0.allSatisfy(\.isFinite) }, "clip \(clip) at \(f)")
            }
        }
        // The first clip turns the arm: two moments of it differ.
        let arm = try #require(s.bones.firstIndex { $0.name == "arm" })
        let turns = s.clips.indices.contains { abs(s.pose($0, 0).bones[arm][1] - s.pose($0, 6).bones[arm][1]) > 0.5 }
        #expect(turns, "no clip turns the arm")
        // Laid out standing: a sprite a part shown, its triangles where they land.
        let atlas = CGSize(width: 32, height: 32)
        let art = GameArt(size: { $0 == s.atlas ? atlas : nil }, skel: { _ in s })
        let standing = GameStanding(key: "art/hero.skel.json", at: CGPoint(x: 500, y: 900), pivot: .zero)
        let sprites = GameScene.sprites(standing, art: art)
        #expect(!sprites.isEmpty && sprites.allSatisfy { $0.key == s.atlas && ($0.mesh?.indices.count ?? 0) % 3 == 0 && $0.mesh?.indices.isEmpty == false })
        #expect(GameScene.bounds(standing, art: art).map { $0.contains(CGPoint(x: 500, y: 890)) || $0.maxY <= 900.5 } == true)
    }

    // MARK: On the GPU

    /// A 32-pixel atlas, red on its left half and blue on its right, and a
    /// skeleton of one bone showing it as a 16-pixel square standing on its
    /// bottom edge.
    private func square(turn: Bool = false, alpha: Double = 1) throws -> (GameImages, GameSkel) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-game-skel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes: [UInt8] = []
        for _ in 0..<32 { for x in 0..<32 { bytes += x < 16 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = CGImageDestinationCreateWithURL(dir.appending(path: "atlas.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))
        let point = { (x: Int, y: Int, u: Int, v: Int) in "{\"uv\": [\(u), \(v)], \"bones\": [[0, 1, [\(x), \(y)]]]}" }
        let turned = turn ? ", \"clips\": [{\"name\": \"idle\", \"frames\": 1, \"bones\": [{\"bone\": 0, \"turned\": [{\"frame\": 0, \"value\": [90, 0]}]}]}]" : ""
        let text = """
        {"atlas": "atlas.png", "atlasSize": [32, 32], "bones": [{"name": "root"}],
         "slots": [{"name": "body", "bone": 0, "color": [1, 1, 1, \(alpha)], "parts": [{"name": "body",
           "points": [\(point(-8, -16, 0, 0)), \(point(8, -16, 32, 0)), \(point(8, 0, 32, 32)), \(point(-8, 0, 0, 32))],
           "triangles": [[0, 1, 2], [0, 2, 3]]}]}]\(turned)}
        """
        let images = GameImages()
        images.root = dir
        return (images, try skel(text))
    }

    private func probe(_ image: CGImage, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let data = image.dataProvider!.data! as Data
        let o = y * image.bytesPerRow + x * 4
        return SIMD3(Int(data[o + 2]), Int(data[o + 1]), Int(data[o]))
    }

    private func drawn(_ s: GameSkel, _ images: GameImages, flip: Bool = false, scale: CGSize? = nil) throws -> CGImage {
        let renderer = try #require(GameRenderer())
        let art = GameArt(size: { images.art.size($0) }, skel: { _ in s })
        let sprites = GameScene.sprites(GameStanding(key: "hero.skel.json", at: CGPoint(x: 32, y: 48), pivot: .zero, flip: flip, scale: scale), art: art)
        let job = GameRenderer.Job(sprites: sprites, camera: GameCamera(center: CGPoint(x: 32, y: 32), zoom: 1), background: .zero)
        return try #require(renderer.picture(job, images: images, width: 64, height: 64))
    }

    @Test func aSkeletonsPartIsDrawnWhereItsBonesCarryItFlippedAboutItsFeet() throws {
        let (images, s) = try square()
        let plain = try drawn(s, images)
        #expect(probe(plain, 28, 40) == SIMD3(255, 0, 0) && probe(plain, 36, 40) == SIMD3(0, 0, 255), "red left of the feet, blue right")
        #expect(probe(plain, 32, 20) == SIMD3(0, 0, 0) && probe(plain, 20, 40) == SIMD3(0, 0, 0), "nothing outside it")
        let flipped = try drawn(s, images, flip: true)
        #expect(probe(flipped, 28, 40) == SIMD3(0, 0, 255) && probe(flipped, 36, 40) == SIMD3(255, 0, 0), "turned about its feet")
        // Squashed about its feet: wider, shorter.
        let squashed = try drawn(s, images, scale: CGSize(width: 1.5, height: 0.5))
        #expect(probe(squashed, 21, 46) == SIMD3(255, 0, 0) && probe(squashed, 32, 36) == SIMD3(0, 0, 0))
        // Its bone turned a quarter: the square lies to the feet's right.
        let (images2, turned) = try square(turn: true)
        let lying = try drawn(turned, images2)
        #expect(probe(lying, 44, 44) != SIMD3(0, 0, 0) && probe(lying, 28, 40) == SIMD3(0, 0, 0), "turned on its bone: \(probe(lying, 44, 44))")
        // A slot's colour: half see-through.
        let (images3, faint) = try square(alpha: 0.5)
        #expect(abs(probe(try drawn(faint, images3), 28, 40).x - 128) <= 2)
    }

    // MARK: Feel

    @Test func aJumpStretchesALandingSquashesAndABlowShakesEasingBack() {
        var jolt = GameJolt()
        let feel = GameFeel(shake: 0.5, squash: 0.5)
        #expect(jolt.scale(at: 0, feel: feel) == nil && jolt.offset(at: 0, feel: feel) == .zero, "nothing yet")
        jolt.felt(GameHappened.jumped, tick: 100)
        let up = jolt.scale(at: 100, feel: feel)
        #expect(up == CGSize(width: 1 - 0.25 * 0.5, height: 1 + 0.3 * 0.5), "stretched tall and thin")
        #expect(jolt.scale(at: 105, feel: feel).map { $0.height > 1 && $0.height < up!.height } == true, "easing back")
        #expect(jolt.scale(at: 110, feel: feel) == nil, "settled after ten ticks")
        jolt.felt(GameHappened.landed, tick: 120)
        #expect(jolt.scale(at: 120, feel: feel).map { $0.width > 1 && $0.height < 1 } == true, "squashed wide and short")
        #expect(jolt.scale(at: 120, feel: GameFeel(squash: 0)) == nil, "none when the game says none")
        // A blow landed shakes a little, a thing beaten more, a hurt most.
        jolt.felt(GameHappened.hit, tick: 200)
        #expect(jolt.shake?.amount == 0.35)
        jolt.felt(GameHappened.killed, tick: 201)
        #expect(jolt.shake?.amount == 0.6)
        jolt.felt(GameHappened.hit, tick: 202)
        #expect(jolt.shake?.amount == 0.6, "a lesser blow while it shakes doesn't soften it")
        jolt.felt(GameHappened.hurt, tick: 300)
        let o = jolt.offset(at: 300, feel: feel)
        #expect(abs(o.dx) <= 6 && abs(o.dy) <= 6 && (o.dx != 0 || o.dy != 0), "at most twelve pixels times how hard, either way: \(o)")
        #expect(abs(o.dx - (GameFX.noise(300, 1, 0) - 0.5) * 2 * 6) < 1e-12, "Proton's noise of the tick")
        #expect(jolt.offset(at: 314, feel: feel) == .zero && jolt.offset(at: 300, feel: GameFeel(shake: 0)) == .zero)
    }

    // MARK: Sound

    @Test func aTicksSoundsAreEachEventsAndCuesOnceAndADeathDrownsTheHurt() {
        let sounds = ["jump": "audio/jump.wav", "land": "audio/land.wav", "hurt": "audio/hurt.wav", "die": "audio/die.wav", "step": "audio/step.wav", "rest": "audio/land.wav"]
        #expect(GameSound.files(GameHappened.jumped, cues: [], sounds: sounds) == ["audio/jump.wav"])
        #expect(GameSound.files(GameHappened.landed | GameHappened.rested, cues: ["step", "nothing"], sounds: sounds) == ["audio/land.wav", "audio/step.wav"],
                "one file once, though two said it; a cue with no sound none")
        #expect(GameSound.files(GameHappened.hurt | GameHappened.died, cues: [], sounds: sounds) == ["audio/die.wav"])
        #expect(GameSound.files(GameHappened.hurt | GameHappened.died, cues: [], sounds: ["hurt": "audio/hurt.wav"]) == ["audio/hurt.wav"], "no death sound: the hurt's")
        #expect(GameSound.files(PlayEvents.dash, cues: [], sounds: sounds).isEmpty)
    }

    @Test func aRoomsMusicIsItsAreas() throws {
        let json = """
        {"areas": [{"id": "crossroads", "name": "Old Crossroads", "music": "audio/dusk.m4a"}, {"id": "deep", "name": "The Deep"}],
         "rooms": [{"id": "crossroads_01", "area": "crossroads"}, {"id": "well", "area": "deep"}]}
        """
        let world = try JSONDecoder().decode(GameWorldMap.self, from: Data(json.utf8))
        #expect(world.music("crossroads_01") == "audio/dusk.m4a" && world.music("well") == nil && world.music("nowhere") == nil)
    }

    @Test func theTemplateSoundsAndFeelsAsProtonsDid() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-game-sound-\(UUID().uuidString)/lumen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GameDocument.create(named: "Lumen", in: dir)
        let doc = try GameDocument(url: dir)
        let game = doc.view.game
        #expect(game.feel == GameFeel(lookahead: 96, shake: 0.5, squash: 0.5))
        #expect(game.audio.effects == 0.8 && game.audio.music == 0.6)
        for event in ["jump", "land", "dash", "swing", "hit", "kill", "hurt", "shot", "rest", "gain"] {
            let file = try #require(game.audio.sounds[event], "\(event) has a sound")
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: file).path), "\(file) was written")
        }
        #expect(doc.view.world.areas.map(\.id) == ["crossroads"] && doc.view.world.rooms.count == 2)
        // Played: a jump says its sound, and the cues a frame says come by name.
        let player = try GamePlayer(doc.run())
        for _ in 0..<60 { player.step() }
        _ = player.takeHappened()
        player.struck = GamePlayer.actions["jump"]!
        player.step()
        let happened = player.takeHappened()
        #expect(GameSound.files(happened, cues: player.takeSaid(), sounds: game.audio.sounds).contains("audio/jump.wav"))
    }
}

/// A bit no sound is put to in these tests.
private enum PlayEvents {
    static let dash = GameHappened.dashed
}
