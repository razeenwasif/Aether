import CanvasCore
import CoreGraphics
import Foundation
import Testing
@testable import GameCore
@testable import GameUI

@MainActor
struct GameImportTests {
    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-game-import-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func opened() throws -> GameWorkspaceModel {
        let model = GameWorkspaceModel(folder: try scratch("games"))
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return model
    }

    /// A canvas painted as a painter lays out a room: a sky that doesn't
    /// move, far hills at a depth, and a ground for the play plane.
    private func painted() throws -> CanvasDocument {
        let doc = try CanvasDocument.create(width: 96, height: 64, preset: .paint, at: try scratch("canvas").appending(path: "forest.canvas", directoryHint: .isDirectory))
        let first = try #require(doc.state.layers.first).id
        _ = doc.apply(.fillRect(layer: first, x: 0, y: 0, width: 96, height: 64, color: RGBA(40, 60, 120)), label: "Sky")
        _ = doc.apply(.setLayer(first, name: "Sky [still]"), label: "Name")
        return doc
    }

    @Test func aPaintersFileFromAnywhereBecomesPlanesInOneStep() throws {
        let model = try opened()
        let doc = try #require(model.document)
        let before = try #require(model.room).planes.count
        // Sent from a canvas, as Send to Game does: a layered file outside
        // the game's folder.
        let psd = try scratch("send").appending(path: "Forest.psd")
        try painted().exportPSD(frame: 0).write(to: psd)
        model.importScale = 4
        model.importFiles([psd])
        #expect(model.noticeIsGood, "\(model.notice ?? "")")
        #expect(FileManager.default.fileExists(atPath: doc.url.appending(path: "art/source/Forest.psd").path), "kept in the game, as it came")
        let room = try #require(model.room)
        #expect(room.planes.count == before + 1)
        let sky = try #require(room.planes.first { $0.name == "Sky" && $0.items.first?.image.hasPrefix("art/forest/") == true }, "\(room.planes.map(\.name))")
        #expect(sky.parallax == 0 && sky.items.first?.scale == 4)
        let image = try #require(sky.items.first?.image)
        #expect(FileManager.default.fileExists(atPath: doc.url.appending(path: image).path) && image.hasPrefix("art/forest/"), "\(image)")
        #expect(model.undoLabel == "Import Forest.psd")
        // It draws: the layout finds its art.
        let sprites = GameScene.layout(room, focal: 1000, view: CGSize(width: 1920, height: 1080), center: CGPoint(x: 960, y: 540), art: model.images.art)
        // With normal maps, its image is pieces and their normal map's.
        #expect(image.hasSuffix(".img.json") && sprites.contains { $0.key.hasPrefix("art/forest/") && $0.normal?.hasPrefix("art/forest/") == true }, "\(image)")
        model.undo()
        #expect(model.room?.planes.count == before, "one step back")
    }

    @Test func aSpriteSheetBecomesAnAnimationAPrefabCanLookLike() throws {
        let model = try opened()
        let doc = try #require(model.document)
        // A canvas's frames as a sheet and its JSON, as Send to Game sends them.
        let canvas = try painted()
        let dir = try scratch("sheet")
        let sheet = try canvas.exportSheet(image: "hero-sheet.png", columns: 0, scale: 1)
        try sheet.png.write(to: dir.appending(path: "hero-sheet.png"))
        try Data(sheet.json.utf8).write(to: dir.appending(path: "hero-sheet.json"))
        model.importFiles([dir.appending(path: "hero-sheet.json")])
        #expect(model.noticeIsGood, "\(model.notice ?? "")")
        let anim = try #require(model.looks.first { $0.hasSuffix(".anim.json") }, "\(model.looks)")
        #expect(FileManager.default.fileExists(atPath: doc.url.appending(path: "art/hero/hero-sheet.png").path), "the sheet came with its JSON")
        #expect(!model.looks.contains { $0.hasPrefix("art/source/") }, "sources aren't looks")
        let text = (try? String(contentsOf: doc.url.appending(path: anim), encoding: .utf8)) ?? "none"
        let sheets = try #require(model.images.anim(anim), "\(text.prefix(600))").sheets
        #expect(!model.looks.contains { sheets.contains($0) }, "nor are the sheets an animation is cut from")
        model.setLook("player", anim)
        let player = try #require(doc.view.prefab("player"))
        #expect(player.sprite == anim && player.pivot == [48, 64], "on the middle of its bottom edge")
        #expect(model.undoLabel == "Set player’s look")
    }

    @Test func aPlanesDepthAndLightAndTheRoomsAirAreSetInOneStepEach() throws {
        let model = try opened()
        let hills = try #require(model.room?.planes.first { $0.id == "hills_far" })
        model.setPlaneDepth(hills.id, 2400)
        #expect(model.room?.planes.first { $0.id == hills.id }?.depth == 2400)
        #expect(model.undoLabel == "Set \(hills.name)’s depth", "by the name the painter sees")
        model.setPlaneLit(hills.id, true)
        #expect(model.room?.planes.first { $0.id == hills.id }?.lit == true)
        let air = try #require(model.room).particles
        #expect(air.map(\.preset) == ["motes"], "the template's")
        model.setAir(air + [GameEmitter(preset: "rain", plane: "fronds")])
        #expect(model.room?.particles.map(\.preset) == ["motes", "rain"])
        model.undo()
        #expect(model.room?.particles.count == 1)
    }

    @Test func aTapQuickerThanATickStillJumps() throws {
        let model = try opened()
        model.play()
        let player = try #require(model.player)
        for _ in 0..<60 { player.step() }
        let ground = player.now.player.y
        // Down and up again before the next tick, as a quick thumb does.
        model.key("KeyZ", down: true)
        model.key("KeyZ", down: false)
        #expect(player.held == 0)
        for _ in 0..<8 { player.step() }
        #expect(player.now.player.y < ground - 4, "it left the ground: \(ground) → \(player.now.player.y)")
        model.stop()
    }

    // MARK: Particles

    @Test func particlesAreProtonsArithmeticToTheBit() {
        // Values from Proton's game-fx.js, run in node.
        #expect(GameFX.noise(7, 3, 2) == 0.6328368179965764)
        #expect(GameFX.noise(-12345, 0, 9) == 0.6195949073880911)
        #expect(GameFX.seed("crossroads_01:0") == -287147086)
        let motes = GameFX.air("motes", over: CGRect(x: 100, y: 200, width: 1920, height: 1080), time: 2.5, seed: -287147086)
        #expect(motes.count == 36)
        let m = motes[3]
        #expect(abs(m.rect.minX - 1423.1360350926752) < 1e-9 && abs(m.rect.minY - 698.3139945252333) < 1e-9)
        #expect(abs(m.rect.width - 7.1336542698554695) < 1e-9 && abs(m.opacity - 0.3797725262049875) < 1e-9 && m.blend == "add")
        let rain = GameFX.air("rain", over: CGRect(x: 0, y: 0, width: 1920, height: 1080), time: 1.25, seed: 42)[5]
        #expect(abs(rain.rect.minX - 985.4900794052519) < 1e-9 && abs(rain.rect.height - 55.145119675435126) < 1e-9 && abs(rain.rot - 4.22525536893776) < 1e-9)
        let spark = GameSpark(kind: "land", at: CGPoint(x: 500, y: 900), start: 1, seed: 131, flip: true)
        let dust = GameFX.burst(spark, time: 1.2)
        #expect(dust.count == 12 && abs(dust[2].rect.minX - 521.2874464189506) < 1e-9 && abs(dust[2].rect.minY - 905.3382536441958) < 1e-9)
        #expect(GameFX.burst(spark, time: 0.9).isEmpty && GameFX.burst(spark, time: 2).isEmpty, "none before it began or after it's over")
        #expect(GameFX.living([spark], time: 3).isEmpty)
    }

    @Test func aRoomsAirHangsOnItsPlaneAndBurstsFlyFromWhatHappened() throws {
        let model = try opened()
        let room = try #require(model.room)
        let view = CGSize(width: 1920, height: 1080), center = CGPoint(x: 1200, y: 1400)
        let still = GameScene.layout(room, focal: 1000, view: view, center: center, art: model.images.art)
        let aired = GameScene.layout(room, focal: 1000, view: view, center: center, art: model.images.art, air: 0)
        #expect(aired.count - still.count == 36, "the template's motes, on the play plane")
        // What a tick did: a landing throws dust both ways from the feet.
        model.play()
        let player = try #require(model.player)
        let landed = GameFX.felt(GameHappened.landed | GameHappened.jumped, now: player.now, before: nil, tick: 60, tall: 1080)
        #expect(landed.map(\.kind) == ["jump", "land", "land"] && landed.allSatisfy { $0.at == player.now.player })
        let flying = GameScene.layout(room, focal: 1000, view: view, center: center, art: model.images.art, time: 0.1, sparks: landed)
        #expect(flying.count > still.count, "the dust is drawn")
        model.stop()
    }
}
