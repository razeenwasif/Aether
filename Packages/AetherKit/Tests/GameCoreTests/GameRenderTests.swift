import AppKit
import Foundation
import ImageIO
import simd
import Testing
import UniformTypeIdentifiers
@testable import GameCore
@testable import GameUI

@MainActor
struct GameRenderTests {
    // MARK: The layout

    private func template() throws -> GameDocument {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-game-render-\(UUID().uuidString)/lumen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GameDocument.create(named: "Lumen", in: dir)
        return try GameDocument(url: dir)
    }

    private func images(_ doc: GameDocument) -> GameImages {
        let images = GameImages()
        images.root = doc.url
        return images
    }

    @Test func aRoomIsLaidOutBackToFrontLitWhereItsPlaneIsAndHalosAfter() throws {
        let doc = try template()
        let room = try #require(doc.room("crossroads_01"))
        let art = images(doc).art
        let view = CGSize(width: 1920, height: 1080), center = CGPoint(x: 2000, y: 1000)
        let player = GameStanding(key: "art/player.png", at: CGPoint(x: 2000, y: 1800), pivot: CGPoint(x: 18, y: 72))
        let sprites = GameScene.layout(room, focal: 1000, view: view, center: center, art: art, standing: [player])
        let main = try #require(room.planes.first { $0.gameplay })
        #expect(main.lit && room.planes.filter(\.lit).map(\.id) == ["main"])
        // The sky stays put on screen: its art is shifted by the whole corner.
        let corner = GameScene.corner(room, view: view, center: center)
        let sky = try #require(room.planes.first { $0.id == "sky" }?.items.first)
        let skySprite = try #require(sprites.first { $0.key == sky.image })
        #expect(abs(skySprite.rect.minX - (Double(sky.at[0]) + corner.x)) < 1e-9)
        // Far hills are hazed by the fog; the play plane is not.
        #expect(sprites.contains { $0.tint.w > 0 && !$0.lit })
        // What stands on the play plane comes after its art, lit with it,
        // before the fronds; the lantern's halo after the play plane, added.
        let me = try #require(sprites.firstIndex { $0.key == "art/player.png" })
        let size = try #require(art.size("art/player.png"))
        #expect(sprites[me].lit && sprites[me].rect == GameScene.stillFrame(size: size, at: player.at, pivot: player.pivot, flip: false))
        let halo = try #require(sprites.firstIndex { $0.key == GameSprite.glow })
        #expect(halo > me && sprites[halo].blend == "add" && !sprites[halo].lit)
        let frond = try #require(room.planes.last?.items.first?.image)
        #expect((sprites.lastIndex { $0.key == frond } ?? 0) > halo, "the fronds are in front of it all")
        // Pixel art on whole pixels.
        let snapped = GameScene.layout(room, focal: 1000, view: view, center: CGPoint(x: 2000.4, y: 1000.7), art: art, standing: [player], snap: true)
        #expect(snapped.allSatisfy { $0.key == GameSprite.glow || ($0.rect.minX == $0.rect.minX.rounded() && $0.rect.minY == $0.rect.minY.rounded()) })
    }

    @Test func aRoomsLightIsItsAmbientAndItsLightsNearestFirstWaveringOnTheClock() throws {
        let doc = try template()
        var room = try #require(doc.room("crossroads_01"))
        let lighting = GameScene.lighting(room, focal: 1000, view: CGSize(width: 1920, height: 1080), center: CGPoint(x: 1000, y: 1500))
        let (r, g, b) = GameScene.rgb("#7b8299")
        #expect(lighting.ambient == SIMD3(Float(r), Float(g), Float(b)), "the template's dusk")
        let lantern = try #require(room.light("lantern"))
        let lamp = try #require(lighting.lamps.first)
        #expect(lamp.at == CGPoint(x: lantern.at[0], y: lantern.at[1]) && lamp.radius == 520 && lamp.height == 80)
        #expect(abs(lamp.color.x - Float(GameScene.rgb("#ffd9a0").0 * 1.2)) < 1e-5, "its colour times its intensity, held still")
        // Twenty lights: the sixteen nearest, nearest first.
        room.lights = (0..<20).map { i in
            try! JSONDecoder().decode(GameLight.self, from: Data(#"{"id":"l\#(i)","plane":"main","at":[\#(1000 + i * 100),1500]}"#.utf8))
        }
        let many = GameScene.lighting(room, focal: 1000, view: CGSize(width: 1920, height: 1080), center: CGPoint(x: 2500, y: 1500))
        #expect(many.lamps.count == 16 && many.lamps.first?.at.x == 2500)
        #expect(many.lamps.map { abs($0.at.x - 2500) } == many.lamps.map { abs($0.at.x - 2500) }.sorted())
        // A wavering light: the same at the same moment, dimmer some moments.
        #expect(GameScene.flicker(lantern, time: 1.25) == GameScene.flicker(lantern, time: 1.25))
        #expect(GameScene.flicker(lantern, time: nil) == 1)
        let seen = (0..<60).map { GameScene.flicker(lantern, time: Double($0) / 60) }
        #expect(seen.min()! < 0.99 && seen.allSatisfy { $0 > 0.89 && $0 <= 1 }, "\(seen.min()!)")
    }

    @Test func theCameraIsAMatrixAndPixelArtStaysOnItsGrid() {
        let camera = GameCamera(center: CGPoint(x: 500, y: 300), zoom: 2)
        let m = camera.matrix(target: CGSize(width: 800, height: 600))
        let middle = m * SIMD4<Float>(500, 300, 0, 1)
        #expect(abs(middle.x) < 1e-5 && abs(middle.y) < 1e-5)
        let corner = m * SIMD4<Float>(300, 150, 0, 1)
        #expect(abs(corner.x + 1) < 1e-5 && abs(corner.y - 1) < 1e-5, "the top-left, y down")
        let snapped = GameCamera(center: CGPoint(x: 100.3, y: 50.6), zoom: 1).snapped(target: CGSize(width: 321, height: 180))
        #expect((snapped.center.x - 160.5).truncatingRemainder(dividingBy: 1) == 0 && (snapped.center.y - 90).truncatingRemainder(dividingBy: 1) == 0)
        // Pixel art in Play: a whole number of the game's pixels a pixel.
        let box = GameStageView.letterbox(view: CGSize(width: 480, height: 270), in: CGSize(width: 1100, height: 800), scale: 2, pixelArt: true)
        #expect(box.pixels == CGSize(width: 1920, height: 1080) && box.frame.size == CGSize(width: 960, height: 540))
        let painted = GameStageView.letterbox(view: CGSize(width: 1920, height: 1080), in: CGSize(width: 1100, height: 800), scale: 2, pixelArt: false)
        #expect(painted.pixels.width == 2200 && painted.frame.minY > 0)
    }

    // MARK: The renderer

    /// A folder of small pictures to draw.
    private func art(_ pictures: [String: (Int, Int, (Int, Int) -> [UInt8])]) throws -> GameImages {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-game-art-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, (w, h, pixel)) in pictures {
            var bytes: [UInt8] = []
            for y in 0..<h { for x in 0..<w { bytes += pixel(x, y) } }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = dir.appending(path: name)
            let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(out, image, nil)
            #expect(CGImageDestinationFinalize(out))
        }
        let images = GameImages()
        images.root = dir
        return images
    }

    /// Red, green and blue at a pixel of a picture the renderer made.
    private func probe(_ image: CGImage, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let data = image.dataProvider!.data! as Data
        let o = y * image.bytesPerRow + x * 4
        return SIMD3(Int(data[o + 2]), Int(data[o + 1]), Int(data[o]))
    }

    private func job(_ sprites: [GameSprite], size: Int = 64) -> GameRenderer.Job {
        GameRenderer.Job(sprites: sprites, camera: GameCamera(center: CGPoint(x: size / 2, y: size / 2), zoom: 1), background: .zero)
    }

    @Test func aLitSpriteIsTheAmbientPlusEachLightFallingOffToItsReach() throws {
        let renderer = try #require(GameRenderer())
        let images = try art(["white.png": (4, 4, { _, _ in [255, 255, 255, 255] })])
        let wall = GameSprite(key: "white.png", rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        let plain = try #require(renderer.picture(job([wall]), images: images, width: 64, height: 64))
        #expect(probe(plain, 32, 32) == SIMD3(255, 255, 255), "unlit, as painted")
        var lit = wall
        lit.lit = true
        var dark = job([lit])
        dark.lighting = GameLighting(ambient: SIMD3(0.2, 0.2, 0.2))
        let dim = try #require(renderer.picture(dark, images: images, width: 64, height: 64))
        #expect(abs(probe(dim, 32, 32).x - 51) <= 1, "the ambient alone: \(probe(dim, 32, 32))")
        var lamp = dark
        lamp.lighting.lamps = [GameLamp(at: CGPoint(x: 8, y: 32), radius: 40, height: 80, color: SIMD3(1, 0.5, 0))]
        let lamplit = try #require(renderer.picture(lamp, images: images, width: 64, height: 64))
        let near = probe(lamplit, 10, 32), far = probe(lamplit, 60, 32)
        #expect(near.x > 230 && near.y > 150 && near.y < near.x && near.z < 60, "warm near the light: \(near)")
        #expect(abs(far.x - 51) <= 1, "nothing past its reach: \(far)")
    }

    @Test func aNormalMapShadesByTheAngleTheLightMeetsIt() throws {
        let renderer = try #require(GameRenderer())
        // A surface facing left: x -1 in the map.
        let images = try art(["white.png": (4, 4, { _, _ in [255, 255, 255, 255] }), "left.png": (4, 4, { _, _ in [0, 128, 128, 255] })])
        let face = GameSprite(key: "white.png", normal: "left.png", rect: CGRect(x: 16, y: 16, width: 32, height: 32), lit: true)
        func lit(from x: Double, flip: Bool = false) throws -> SIMD3<Int> {
            var f = face
            f.flip = flip
            var j = job([f])
            j.lighting = GameLighting(ambient: .zero, lamps: [GameLamp(at: CGPoint(x: x, y: 32), radius: 200, height: 10, color: SIMD3(1, 1, 1))])
            return probe(try #require(renderer.picture(j, images: images, width: 64, height: 64)), 32, 32)
        }
        let fromLeft = try lit(from: -40), fromRight = try lit(from: 104)
        #expect(fromLeft.x > 100 && fromRight.x < 10, "lit from the side it faces: \(fromLeft) against \(fromRight)")
        let flipped = try lit(from: 104, flip: true)
        #expect(flipped.x > 100, "flipped, it faces the other way")
    }

    @Test func theFinishBloomsGradesAndDarkensTheCorners() throws {
        let renderer = try #require(GameRenderer())
        // An inverting grade: n = 2, so 4 × 2, each cell its colour's opposite.
        let images = try art(["white.png": (4, 4, { _, _ in [255, 255, 255, 255] }),
                              "invert.png": (4, 2, { x, y in [UInt8(255 * (1 - x % 2)), UInt8(255 * (1 - y)), UInt8(255 * (1 - x / 2)), 255] })])
        let square = GameSprite(key: "white.png", rect: CGRect(x: 24, y: 24, width: 16, height: 16))
        var plain = job([square])
        plain.post = GamePost(bloom: 0, vignette: 0)
        let none = try #require(renderer.picture(plain, images: images, width: 64, height: 64))
        #expect(probe(none, 21, 32) == .zero)
        var bloomed = plain
        bloomed.post = GamePost(bloom: 1, vignette: 0)
        let glow = try #require(renderer.picture(bloomed, images: images, width: 64, height: 64))
        #expect(probe(glow, 21, 32).x > 5, "light spills past the square: \(probe(glow, 21, 32))")
        var graded = plain
        graded.post = GamePost(bloom: 0, grade: "invert.png", vignette: 0)
        let inverted = try #require(renderer.picture(graded, images: images, width: 64, height: 64))
        #expect(probe(inverted, 32, 32).x < 8 && probe(inverted, 4, 4).x > 247, "white to black, black to white")
        let wall = GameSprite(key: "white.png", rect: CGRect(x: 0, y: 0, width: 64, height: 64), opacity: 0.5)
        var vignetted = job([wall])
        vignetted.post = GamePost(bloom: 0, vignette: 1)
        let dark = try #require(renderer.picture(vignetted, images: images, width: 64, height: 64))
        #expect(probe(dark, 32, 32).x > 120 && probe(dark, 0, 0).x < 20, "\(probe(dark, 32, 32)) in the middle, \(probe(dark, 0, 0)) in a corner")
    }

    @Test func pixelArtIsDrawnAtItsOwnSizeAndScaledUpSharp() throws {
        let renderer = try #require(GameRenderer())
        let images = try art(["checks.png": (2, 2, { x, y in (x + y) % 2 == 0 ? [255, 255, 255, 255] : [0, 0, 0, 255] })])
        var j = GameRenderer.Job(sprites: [GameSprite(key: "checks.png", rect: CGRect(x: 0, y: 0, width: 8, height: 8))],
                                 camera: GameCamera(center: CGPoint(x: 4, y: 4), zoom: 1), background: .zero)
        j.pixelArt = true
        j.pictureSize = CGSize(width: 8, height: 8)
        let big = try #require(renderer.picture(j, images: images, width: 64, height: 64))
        // Four pixels of the art a check, eight of the screen a pixel of the art.
        #expect(probe(big, 0, 0) == SIMD3(255, 255, 255) && probe(big, 31, 31) == SIMD3(255, 255, 255))
        #expect(probe(big, 32, 0) == .zero && probe(big, 33, 1) == .zero, "a sharp edge, no blur across it")
        j.pixelArt = false
        let soft = try #require(renderer.picture(j, images: images, width: 64, height: 64))
        let edge = probe(soft, 32, 16).x
        #expect(edge > 10 && edge < 245, "painted art is smooth across it: \(edge)")
    }

    @Test func theTemplateRoomRendersLitByItsLantern() throws {
        let doc = try template()
        let images = images(doc)
        let renderer = try #require(GameRenderer())
        let room = try #require(doc.room("crossroads_01"))
        let view = CGSize(width: 1920, height: 1080), center = CGPoint(x: 1200, y: 1500)
        var j = GameRenderer.Job(sprites: GameScene.layout(room, focal: 1000, view: view, center: center, art: images.art, air: 2),
                                 camera: GameCamera(center: center, zoom: 0.5), post: doc.view.game.post)
        j.lighting = GameScene.lighting(room, focal: 1000, view: view, center: center)
        let picture = try #require(renderer.picture(j, images: images, width: 960, height: 540))
        // The ground under the lantern is warmer and brighter than the ground
        // far from it.
        let lantern = try #require(room.light("lantern"))
        func screen(_ x: Int, _ y: Int) -> (Int, Int) { (Int((Double(x) - center.x) * 0.5 + 480), Int((Double(y) - center.y) * 0.5 + 270)) }
        let (lx, ly) = screen(lantern.at[0], 1830)
        let (fx, fy) = screen(lantern.at[0] + 900, 1830)
        let near = probe(picture, lx, ly), far = probe(picture, fx, fy)
        #expect(near.x > far.x + 20, "lit \(near) against unlit \(far)")
        let out = FileManager.default.temporaryDirectory.appending(path: "aether-game-stage.png")
        let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, picture, nil)
        _ = CGImageDestinationFinalize(dest)
    }
}
