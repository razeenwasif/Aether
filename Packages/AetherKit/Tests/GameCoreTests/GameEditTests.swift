import AppKit
import Foundation
import Testing
@testable import GameCore
@testable import GameUI

@MainActor
struct GameEditTests {
    private func opened() throws -> GameWorkspaceModel {
        let games = FileManager.default.temporaryDirectory.appending(path: "aether-game-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = GameWorkspaceModel(folder: games)
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return model
    }

    @Test func collisionIsDrawnAPointAtATimeAndEditedByItsPoints() throws {
        let model = try opened()
        let before = try #require(model.room).collision.count
        model.drawKind = "oneway"
        model.addLine([CGPoint(x: 100, y: 1500), CGPoint(x: 300.4, y: 1500), CGPoint(x: 500, y: 1450)])
        let room = try #require(model.room)
        #expect(room.collision.count == before + 1)
        guard case let .shape(id) = model.selection else { Issue.record("the new line is chosen"); return }
        #expect(id == "oneway_1" && room.shape(id)?.kind == "oneway" && room.shape(id)?.points == [[100, 1500], [300, 1500], [500, 1450]])
        model.movePoint(id, 1, to: CGPoint(x: 320, y: 1480))
        #expect(model.room?.shape(id)?.points[1] == [320, 1480])
        model.insertPoint(id, at: 1, CGPoint(x: 200, y: 1490))
        #expect(model.room?.shape(id)?.points.count == 4 && model.room?.shape(id)?.points[1] == [200, 1490])
        model.removePoint(id, 1)
        model.removePoint(id, 1)
        #expect(model.room?.shape(id)?.points == [[100, 1500], [500, 1450]])
        model.removePoint(id, 0)
        #expect(model.room?.shape(id)?.points.count == 2 && model.notice?.contains("two points") == true, "a line keeps two")
        model.moveLine(id, by: 10, -20)
        #expect(model.room?.shape(id)?.points == [[110, 1480], [510, 1430]])
        model.setLineKind(id, "hazard")
        model.setLineClosed(id, true)
        #expect(model.room?.shape(id)?.kind == "hazard" && model.room?.shape(id)?.closed == true)
        model.removeSelected()
        #expect(model.room?.shape(id) == nil && model.selection == nil)
        model.undo()
        #expect(model.room?.shape(id) != nil, "one step back")
    }

    @Test func lightsSpawnsAndThingsArePlacedAndMoved() throws {
        let model = try opened()
        let lights = try #require(model.room).lights.count
        model.addLight(at: CGPoint(x: 900, y: 1600))
        guard case let .light(id) = model.selection else { Issue.record("the new light is chosen"); return }
        let light = try #require(model.room?.light(id))
        #expect(model.room?.lights.count == lights + 1 && light.plane == "main" && light.at == [900, 1600] && light.radius == 400)
        model.moveLight(id, by: 50, 0)
        model.setLight(id, "radius", 250)
        model.setLight(id, "color", "#a0c0ff")
        #expect(model.room?.light(id)?.at == [950, 1600] && model.room?.light(id)?.radius == 250 && model.room?.light(id)?.color == "#a0c0ff")

        model.moveSpawn("start", by: -20, 0)
        #expect(model.room?.spawn("start")?.at == [380, 1800])

        #expect(model.placeable.map(\.id).contains("crawler") && !model.placeable.map(\.id).contains("player"))
        model.place("crawler", at: CGPoint(x: 1200, y: 1800))
        #expect(model.selection == .entity("crawler_1") && model.room?.entity("crawler_1")?.at == [1200, 1800])
        model.place("crawler", at: CGPoint(x: 1300, y: 1800))
        #expect(model.room?.entity("crawler_2") != nil, "a fresh id each")
        model.place("transition", at: CGPoint(x: 2000, y: 1800))
        #expect(model.room?.entity("transition_1")?.rect == [1970, 1600, 60, 200])
        model.place("ability_pickup", at: CGPoint(x: 1500, y: 1700))
        #expect(model.room?.entity("ability_pickup_1")?.grants == "dash")
        // A crawler placed is in the next run.
        model.play()
        let things = try #require(model.player).now.drawn.filter { $0.who != 0 }.count
        #expect(things >= 2, "the crawlers placed are run: \(things)")
        model.stop()
    }

    /// A small animation written into the game: a sheet of four frames, an
    /// idle clip and a run.
    private func animate(_ model: GameWorkspaceModel) throws {
        let doc = try #require(model.document)
        let (w, h) = (48, 80)
        let ctx = CGContext(data: nil, width: w * 4, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<4 {
            ctx.setFillColor(CGColor(red: 0.2 + 0.2 * Double(i), green: 0.6, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: i * w + 8, y: 0, width: 32, height: 72))
        }
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: doc.url.appending(path: "art/hero.png"))
        let frames = (0..<4).map { ["sheet": 0, "rect": [$0 * w, 0, w, h], "offset": [0, 0], "ms": 100] as [String: Any] }
        let anim: [String: Any] = ["format": 1, "size": [w, h], "sheets": ["art/hero.png"], "frames": frames,
                                   "clips": [["name": "idle", "from": 0, "to": 0], ["name": "run", "from": 1, "to": 3]]]
        try JSONSerialization.data(withJSONObject: anim).write(to: doc.url.appending(path: "art/hero.anim.json"))
        #expect(doc.apply([.set(["sprite"], "art/hero.anim.json"), .set(["pivot"], [24, 80])], to: "prefab:player", label: "Animate"))
    }

    @Test func anAnimationIsDrawnByItsFramesStillAndInPlay() throws {
        let model = try opened()
        try animate(model)
        let anim = try #require(model.images.anim("art/hero.anim.json"))
        #expect(anim.frames.count == 4 && anim.restingFrame() == 0 && anim.restingFrame(["idle": "run"]) == 1)
        let cut = try #require(model.images.frame("art/hero.anim.json", 2))
        #expect(cut.image.width == 48 && cut.image.height == 80)
        // Placed on its feet, and flipped about them.
        let frame = GameScene.animFrame(cut.frame, at: CGPoint(x: 100, y: 200), pivot: CGPoint(x: 24, y: 80), flip: false)
        #expect(frame == CGRect(x: 76, y: 120, width: 48, height: 80))
        var trimmed = cut.frame
        trimmed.offset = [8, 4]
        trimmed.rect[2] = 32
        #expect(GameScene.animFrame(trimmed, at: CGPoint(x: 100, y: 200), pivot: CGPoint(x: 24, y: 80), flip: true) == CGRect(x: 84, y: 124, width: 32, height: 80))
        #expect(GameScene.stillFrame(size: CGSize(width: 36, height: 72), at: CGPoint(x: 100, y: 200), pivot: CGPoint(x: 10, y: 72), flip: true).minX == 74)
        // In Play, the player's record names the frame the run is at: still
        // at first, then the run's frames as it runs.
        model.play()
        let player = try #require(model.player)
        let still = try #require(player.now.drawn.first { $0.who == 0 })
        #expect(player.info.sprites.contains("art/hero.anim.json") && still.frame == 0)
        player.held = GamePlayer.actions["right"]!
        var seen = Set<Int>()
        for _ in 0..<60 {
            player.step()
            if let me = player.now.drawn.first(where: { $0.who == 0 }) { seen.insert(me.frame) }
        }
        #expect(seen.isSuperset(of: [1, 2, 3]), "the run's frames: \(seen.sorted())")
        model.stop()
    }

    @Test func aClickLandsOnPointsThenThingsThenLines() throws {
        let model = try opened()
        let view = GameStageView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.model = model
        let doc = try #require(model.document)
        view.update(revision: doc.revision, roomID: model.roomID, selection: nil, playing: false, fit: model.fitRequest)
        let room = try #require(model.room)
        let line = try #require(room.collision.first { $0.points.count >= 2 })
        let (a, b) = (line.points[0], line.points[1])
        let middle = CGPoint(x: Double(a[0] + b[0]) / 2, y: Double(a[1] + b[1]) / 2)
        #expect(view.hit(middle) == .line(line.id, 0), "\(String(describing: view.hit(middle)))")
        #expect(view.hit(CGPoint(x: 700, y: 1800)) == .entity("bench"), "a thing before the line under it")
        #expect(view.hit(CGPoint(x: 400, y: 1790)) == .spawn("start"))
        model.selection = .shape(line.id)
        view.update(revision: doc.revision, roomID: model.roomID, selection: model.selection, playing: false, fit: model.fitRequest)
        #expect(view.hit(CGPoint(x: a[0], y: a[1])) == .point(line.id, 0), "the chosen line's points first")
    }
}
