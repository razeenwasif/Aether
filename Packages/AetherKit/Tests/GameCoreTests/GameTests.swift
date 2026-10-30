import CoreGraphics
import Foundation
import Testing
@testable import GameCore
@testable import GameUI

@MainActor
struct GameTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "aether-games-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func newGame(_ name: String = "Lumen") throws -> GameDocument {
        let dir = folder().appending(path: "lumen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GameDocument.create(named: name, in: dir)
        return try GameDocument(url: dir)
    }

    @Test func aNewGameIsProtonsTemplateReadWhole() throws {
        let doc = try newGame()
        #expect(doc.name == "Lumen")
        #expect(doc.view.rooms.map(\.id) == ["crossroads_01", "crossroads_02"])
        #expect(Set(doc.view.prefabs.map(\.id)).isSuperset(of: ["player", "crawler"]))
        let room = try #require(doc.room("crossroads_01"))
        #expect(room.size == [3840, 2160])
        #expect(room.planes.map(\.id) == ["sky", "hills_far", "hills_near", "main", "fronds"])
        #expect(room.planes.filter(\.gameplay).map(\.id) == ["main"])
        #expect(room.collision.map(\.kind).contains("hazard") && room.collision.map(\.kind).contains("oneway"))
        #expect(room.entity("bench")?.at == [700, 1800] && room.entity("to_east")?.to?.room == "crossroads_02")
        #expect(room.spawns.map(\.id) == ["start", "east"])
        #expect(room.fog?.amount == 0.5)
        #expect(doc.view.game.view.focal == 1000 && doc.view.game.view.width == 1920)
        #expect(doc.unsaved.isEmpty)
    }

    @Test func anEditIsOneStepUndoneWhereverItWasMadeAndHeldUntilSaved() throws {
        let doc = try newGame()
        let target = "room:crossroads_01"
        #expect(doc.apply([.set(["entities", "#bench", "at"], [760, 1800])], to: target, label: "Move bench"))
        #expect(doc.room("crossroads_01")?.entity("bench")?.at == [760, 1800])
        #expect(doc.undoLabel == "Move bench")
        #expect(doc.unsaved == ["rooms/crossroads_01.room.json"])
        // Another room's edit, then ⌘Z twice: the newest first, wherever.
        let things = try #require(doc.room("crossroads_02")?.entities.count)
        #expect(doc.apply([.remove(["entities", "#\(doc.room("crossroads_02")!.entities[0].id)"])], to: "room:crossroads_02", label: "Remove"))
        #expect(doc.room("crossroads_02")?.entities.count == things - 1)
        doc.undo()
        #expect(doc.room("crossroads_02")?.entities.count == things)
        #expect(doc.undoLabel == "Move bench")
        doc.undo()
        #expect(doc.room("crossroads_01")?.entity("bench")?.at == [700, 1800])
        doc.redo()
        #expect(doc.room("crossroads_01")?.entity("bench")?.at == [760, 1800])
        // Refused whole, with the core's reason; nothing changed.
        #expect(!doc.apply([.set(["size"], "wide")], to: target, label: "Break"))
        #expect(doc.refusal != nil)
        #expect(doc.room("crossroads_01")?.size == [3840, 2160])
        let written = try doc.save()
        #expect(written.contains("rooms/crossroads_01.room.json") && doc.unsaved.isEmpty)
        let reopened = try GameDocument(url: doc.url)
        #expect(reopened.room("crossroads_01")?.entity("bench")?.at == [760, 1800])
    }

    @Test func playStepsTheRunOnAFixedClockAndItsReplayEndsTheSame() throws {
        let doc = try newGame()
        let player = try GamePlayer(doc.run())
        #expect(player.info.tick == 60 && player.info.rooms.count == 2)
        let start = player.now.player
        player.held = GamePlayer.actions["right"]!
        // Half a second of the clock: 30 ticks, whatever the screen did.
        for _ in 0..<5 { player.advance(by: 0.1) }
        #expect(abs(player.now.tick - 30) <= 1)
        #expect(player.now.player.x > start.x + 50, "walked right: \(start) to \(player.now.player)")
        #expect(player.now.drawn.contains { $0.who == 0 }, "the player is drawn")
        player.held = GamePlayer.actions["jump"]!
        for _ in 0..<20 { player.step() }
        let check = try player.replayCheck()
        #expect(check.same && check.ticks == player.now.tick)
        // A stall doesn't run away: a quarter second at most.
        let before = player.now.tick
        player.advance(by: 5)
        #expect(player.now.tick - before <= 15)
    }

    @Test func keysAreTheGamesOwnOrTheDefaults() {
        let keys = GamePlayer.keys([:])
        #expect(keys["ArrowLeft"] == 1 && keys["KeyZ"] == 16 && keys["Space"] == 16 && keys["ShiftLeft"] == 64)
        let custom = GamePlayer.keys(["jump": ["KeyK", "pad:a"]])
        #expect(custom["KeyK"] == 16 && custom["KeyZ"] == nil && custom["pad:a"] == nil)
        #expect(GameStageView.keyName(6) == "KeyZ" && GameStageView.keyName(123) == "ArrowLeft" && GameStageView.keyName(49) == "Space")
    }

    @Test func parallaxIsProtonsArithmetic() throws {
        let doc = try newGame()
        let room = try #require(doc.room("crossroads_01"))
        let sky = room.planes[0], hills = room.planes[1], main = room.planes[3], fronds = room.planes[4]
        #expect(GameScene.factor(sky, focal: 1000) == 0, "the sky says so")
        #expect(abs(GameScene.factor(hills, focal: 1000) - 1000.0 / 2500) < 1e-9)
        #expect(GameScene.factor(main, focal: 1000) == 1)
        #expect(GameScene.factor(fronds, focal: 1000) > 1, "in front, it rushes past")
        let view = CGSize(width: 1920, height: 1080)
        // Held inside the room: at its left edge, the corner is 0.
        #expect(GameScene.corner(room, view: view, center: CGPoint(x: 100, y: 1800)) == CGPoint(x: 0, y: 1080))
        #expect(GameScene.corner(room, view: view, center: CGPoint(x: 2000, y: 1000)) == CGPoint(x: 1040, y: 460))
        #expect(GameScene.shift(1, corner: CGPoint(x: 500, y: 300)) == .zero)
        #expect(GameScene.shift(0, corner: CGPoint(x: 500, y: 300)) == CGPoint(x: 500, y: 300))
        // Far hills take the fog; the play plane never does.
        #expect(GameScene.haze(room, hills).3 > 0 && GameScene.haze(room, main).3 == 0)
    }

    @Test func theWorkspaceMakesOpensEditsPlaysAndCloses() throws {
        let games = folder()
        let model = GameWorkspaceModel(folder: games)
        #expect(model.games.isEmpty)
        model.newName = "Lumen Two"
        model.create()
        let document = try #require(model.document, "\(model.notice ?? "")")
        #expect(document.url.lastPathComponent == "lumen_two" && model.roomID == "crossroads_01")
        #expect(model.games.map(\.name) == ["Lumen Two"])
        model.selected = "bench"
        model.moveEntity("bench", by: 40, -10)
        #expect(model.room?.entity("bench")?.at == [740, 1790])
        model.setPlace("to_east", x: 3700, y: 1400)
        #expect(model.room?.entity("to_east")?.rect == [3700, 1400, 40, 300])
        model.close()
        #expect(model.document != nil && model.notice?.contains("unsaved") == true, "not closed with changes unsaved")
        model.play()
        #expect(model.playing && model.health.most > 0)
        model.player?.held = GamePlayer.actions["right"]!
        for _ in 0..<40 { model.player?.step() }
        model.stop()
        #expect(!model.playing && model.notice?.contains("same state") == true, "\(model.notice ?? "")")
        model.removeSelected()
        #expect(model.room?.entity("bench") == nil && model.selected == nil)
        model.undo()
        #expect(model.room?.entity("bench") != nil)
        model.saveNow()
        model.close()
        #expect(model.document == nil)
        try? FileManager.default.removeItem(at: games)
    }
}
