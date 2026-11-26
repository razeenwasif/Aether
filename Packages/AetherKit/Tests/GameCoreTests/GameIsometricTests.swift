import CoreGraphics
import Foundation
import Testing
@testable import GameCore
@testable import GameUI

/// An isometric game: made from its template, its kind set, what stands
/// drawn by its feet, walls snapped to the ground's grid, and played on
/// the ground.
@MainActor
struct GameIsometricTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "aether-games-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func newGame() throws -> GameDocument {
        let dir = folder().appending(path: "ruin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GameDocument.create(named: "Ruin", in: dir, kind: "isometric")
        return try GameDocument(url: dir)
    }

    @Test func aNewIsometricGameIsTheCourtyard() throws {
        let doc = try newGame()
        #expect(doc.view.game.isIsometric && doc.view.game.groundDepth == 0.5)
        #expect(doc.view.rooms.map(\.id) == ["courtyard"])
        let room = try #require(doc.room("courtyard"))
        #expect(room.planes.filter(\.gameplay).map(\.id) == ["main"])
        #expect(Set(room.collision.map(\.kind)) == ["solid", "hazard"])
        #expect(room.entity("pillar")?.at == [880, 720] && room.entity("crawler_1") != nil)
        // A side-on game says nothing of the ground, and isn't isometric.
        let side = folder().appending(path: "side", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try GameDocument.create(named: "Side", in: side)
        let sideOn = try GameDocument(url: side)
        #expect(!sideOn.view.game.isIsometric && sideOn.view.game.niche == "metroidvania")
    }

    @Test func whatStandsIsDrawnByItsFeetFurthestFirst() {
        let pivot = CGPoint(x: 10, y: 20)
        let player = GameStanding(key: "p", at: CGPoint(x: 0, y: 700), pivot: pivot)
        let pillar = GameStanding(key: "pillar", at: CGPoint(x: 0, y: 720), pivot: pivot)
        let crawler = GameStanding(key: "c", at: CGPoint(x: 0, y: 620), pivot: pivot)
        let level = GameStanding(key: "level", at: CGPoint(x: 0, y: 700), pivot: pivot)
        #expect(GameScene.byDepth([pillar, player, crawler, level]).map(\.key) == ["c", "p", "level", "pillar"], "nearer over further; a tie keeps its order")
        // Walking below the pillar's feet puts the player in front of it.
        var nearer = player
        nearer.at.y = 760
        #expect(GameScene.byDepth([nearer, pillar]).map(\.key) == ["pillar", "p"])
        // The layout keeps the order it's given unless asked for depth.
        let room = GameRoom.testRoom
        let art = GameArt(size: { _ in CGSize(width: 20, height: 20) })
        let side = GameScene.layout(room, focal: 1000, view: CGSize(width: 1920, height: 1080), center: .zero, art: art, standing: [pillar, player])
        let iso = GameScene.layout(room, focal: 1000, view: CGSize(width: 1920, height: 1080), center: .zero, art: art, standing: [pillar, player], depth: true)
        #expect(side.map(\.key) == ["pillar", "p"] && iso.map(\.key) == ["p", "pillar"])
    }

    @Test func shiftSnapsALineToTheGroundsWays() {
        let o = CGPoint(x: 100, y: 100)
        let along = GameScene.snap(CGPoint(x: 300, y: 196), from: o, isometric: true)
        #expect(abs((along.x - o.x) - 2 * (along.y - o.y)) <= 1, "along the 2:1 diagonal: \(along)")
        #expect(GameScene.snap(CGPoint(x: 300, y: 120), from: o, isometric: true) == CGPoint(x: 300, y: 100), "across")
        #expect(GameScene.snap(CGPoint(x: 110, y: 400), from: o, isometric: true) == CGPoint(x: 100, y: 400), "up and down")
        let back = GameScene.snap(CGPoint(x: -100, y: 200), from: o, isometric: true)
        #expect(back.x < o.x && abs((o.x - back.x) - 2 * (back.y - o.y)) <= 1, "the other diagonal: \(back)")
        // Side-on, the diagonal is 45°.
        #expect(GameScene.snap(CGPoint(x: 200, y: 190), from: o, isometric: false) == CGPoint(x: 195, y: 195))
    }

    @Test func theGridRunsAlongTheGroundsDiagonalsOverTheRoom() {
        let size = CGSize(width: 2400, height: 1600)
        let lines = GameScene.grid(size)
        #expect(lines.count > 60)
        for (a, b) in lines {
            let slope = (b.y - a.y) / (b.x - a.x)
            #expect(abs(abs(slope) - 0.5) < 1e-9)
            for p in [a, b] { #expect(p.x >= -0.5 && p.x <= size.width + 0.5 && p.y >= -0.5 && p.y <= size.height + 0.5) }
        }
        // The courtyard's floor, laid by the template, has its flags' corners
        // on the grid: its middle is a crossing.
        #expect(lines.contains { (a, b) in
            let t = (1216 - a.x) / (b.x - a.x)
            return t >= 0 && t <= 1 && abs(a.y + t * (b.y - a.y) - 800) < 1e-6
        })
    }

    @Test func theKindIsSetAsOneStepAndPlayWalksOnTheGround() throws {
        let games = folder()
        let model = GameWorkspaceModel(folder: games)
        model.newName = "Ruin"
        model.newKind = "isometric"
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        #expect(model.isIsometric && model.roomID == "courtyard")
        // Play: up walks away up the screen, at half speed, and nothing falls.
        model.play()
        let player = try #require(model.player)
        let start = player.now.player
        player.held = GamePlayer.actions["up"]!
        for _ in 0..<30 { player.step() }
        let up = player.now.player
        #expect(up.y < start.y - 20 && up.x == start.x, "walked up: \(start) to \(up)")
        player.held = GamePlayer.actions["right"]!
        for _ in 0..<30 { player.step() }
        let across = player.now.player
        #expect(across.x - up.x > (up.y - start.y).magnitude * 1.5, "across goes further than away: \(up) to \(across)")
        #expect(abs(across.y - up.y) < 10, "letting go of up slows to a stop, not a jolt: \(up) to \(across)")
        model.stop()
        #expect(model.notice?.contains("same state") == true, "\(model.notice ?? "")")
        // Side-on again, as one step, and back.
        model.setKind("metroidvania")
        #expect(!model.isIsometric && model.document?.undoLabel == "Make It Side-On")
        model.undo()
        #expect(model.isIsometric)
        try? FileManager.default.removeItem(at: games)
    }
}

private extension GameRoom {
    /// A room of one play plane and nothing on it.
    static var testRoom: GameRoom {
        let json = #"{"id": "t", "size": [1920, 1080], "planes": [{"id": "main", "gameplay": true}]}"#
        return try! JSONDecoder().decode(GameRoom.self, from: Data(json.utf8))
    }
}
