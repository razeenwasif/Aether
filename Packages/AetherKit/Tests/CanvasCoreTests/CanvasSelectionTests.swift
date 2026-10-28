import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CanvasCore
@testable import CanvasUI

struct CanvasTransformTests {
    private let rect = CGRect(x: 10, y: 20, width: 8, height: 4)

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 1e-9 }

    @Test func aWholeMoveBecomesAnInverseOfWholePixels() throws {
        var t = CanvasTransform(rect)
        #expect(t.isIdentity)
        t = t.dragged(rect, .move, from: CGPoint(x: 12, y: 21), to: CGPoint(x: 15, y: 19))
        #expect(t.isWholeMove && !t.isIdentity)
        let op = try #require(t.op(rect, width: 64, height: 64))
        #expect(op.bounds == [13, 18, 8, 4])
        #expect(op.inverse == [65536, 0, -3 * 65536, 0, 65536, 2 * 65536], "each pixel came from 3 left and 2 down")
        #expect(t.dragged(rect, .move, from: .zero, to: CGPoint(x: 200, y: 0)).op(rect, width: 64, height: 64) == nil, "off the canvas")
    }

    @Test func aCornerScalesKeepingTheOppositeCorner() {
        let t = CanvasTransform(rect).dragged(rect, .se, from: CGPoint(x: 18, y: 24), to: CGPoint(x: 26, y: 28))
        let c = t.corners(rect)
        #expect(near(c[0], CGPoint(x: 10, y: 20)) && near(c[3], CGPoint(x: 26, y: 28)), "twice the size, the top left where it was")
        #expect(abs(t.sx - 2) < 1e-9 && abs(t.sy - 2) < 1e-9)
        let free = CanvasTransform(rect).dragged(rect, .se, from: CGPoint(x: 18, y: 24), to: CGPoint(x: 26, y: 24), free: true)
        #expect(abs(free.sx - 2) < 1e-9 && abs(free.sy - 1) < 1e-9, "⇧ scales one way only")
        let side = CanvasTransform(rect).dragged(rect, .e, from: CGPoint(x: 18, y: 22), to: CGPoint(x: 22, y: 30))
        #expect(abs(side.sx - 1.5) < 1e-9 && side.sy == 1, "a side scales across")
    }

    @Test func aTurnSnapsAndAQuarterTurnSwapsTheSides() throws {
        // About the middle (14, 22): from straight right to straight down.
        let t = CanvasTransform(rect).dragged(rect, .rotate, from: CGPoint(x: 30, y: 22), to: CGPoint(x: 14.3, y: 40), snap: true)
        #expect(abs(t.angle - .pi / 2) < 1e-9, "snapped to 90°")
        let op = try #require(t.op(rect, width: 64, height: 64))
        #expect(op.bounds == [12, 18, 4, 8])
        #expect(op.inverse[0] == 0 && op.inverse[1] == 65536 && op.inverse[3] == -65536 && op.inverse[4] == 0)
        #expect(!t.isWholeMove)
    }

    @Test func handlesAreFoundWithTheMiddleKeptForMoving() {
        let t = CanvasTransform(rect)
        #expect(t.hit(rect, CGPoint(x: 10, y: 20), reach: 2) == .nw)
        #expect(t.hit(rect, CGPoint(x: 18, y: 22), reach: 2) == .e)
        #expect(t.hit(rect, CGPoint(x: 14, y: 22), reach: 2) == .move)
        #expect(t.hit(rect, CGPoint(x: 40, y: 40), reach: 2) == .rotate)
    }
}

@MainActor
struct CanvasSelectionTests {
    private let red = RGBA(255, 0, 0)
    private let blue = RGBA(0, 0, 255)

    private func model() throws -> CanvasWorkspaceModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-canvases-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = CanvasWorkspaceModel(folder: folder)
        model.stageSize = CGSize(width: 1400, height: 900)
        model.clipboard = NSPasteboard(name: NSPasteboard.Name("aether-tests-\(UUID().uuidString)"))
        model.newCanvas(named: "Selections", preset: .pixel, width: 64, height: 64)
        return model
    }

    private func key(_ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func size(ofPNG data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    @Test func aSelectionMovedIsOneStepAndTheSelectionGoesWithIt() throws {
        let model = try model()
        let doc = try #require(model.document)
        let sprite = try #require(model.currentLayer).id
        model.change(.fillRect(layer: sprite, x: 4, y: 4, width: 8, height: 6, color: red), label: "Fill")
        #expect(doc.outline.isEmpty && doc.selected == nil)

        model.selectDragged(from: CGPoint(x: 4.2, y: 4.5), to: CGPoint(x: 11.7, y: 9.9), lasso: [], mode: .replace)
        #expect(doc.selected == CGRect(x: 4, y: 4, width: 8, height: 6) && !doc.outline.isEmpty)

        model.tool = .move
        #expect(model.startTransform(free: false))
        let moving = try #require(model.moving)
        #expect(moving.rect == CGRect(x: 4, y: 4, width: 8, height: 6) && moving.image.width == 8)
        #expect(doc.pick(x: 5, y: 5) == nil || doc.pick(x: 5, y: 5)?.a == 0, "lifted off the layer while it moves")
        model.moving?.transform = moving.transform.dragged(moving.rect, .move, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 25, y: 5))
        model.finishTransform()
        #expect(model.moving == nil && doc.state.undo == "Move")
        #expect(doc.pick(x: 25, y: 5) == red && doc.pick(x: 5, y: 5)?.a == 0)
        #expect(doc.selected == CGRect(x: 24, y: 4, width: 8, height: 6), "the selection moves with it")

        model.undo()
        #expect(doc.pick(x: 5, y: 5) == red && doc.selected == CGRect(x: 4, y: 4, width: 8, height: 6))

        // Left, nothing changes; a quarter turn with ⌘T, the sides swap.
        #expect(model.startTransform(free: true))
        model.moving?.transform.dx = 10
        model.leaveTransform()
        #expect(doc.pick(x: 5, y: 5) == red && doc.state.redo == "Move")
        #expect(model.startTransform(free: true))
        model.moving?.transform.angle = .pi / 2
        model.finishTransform()
        #expect(doc.state.undo == "Transform" && doc.selected == CGRect(x: 5, y: 3, width: 6, height: 8))
    }

    @Test func copyPastesWhereItWasAndAPictureFromElsewhereComesInAsALayer() throws {
        let model = try model()
        let doc = try #require(model.document)
        let sprite = try #require(model.currentLayer).id
        model.paste()
        #expect(model.notice?.hasPrefix("Nothing’s copied") == true)

        model.change(.fillRect(layer: sprite, x: 10, y: 10, width: 5, height: 3, color: blue), label: "Fill")
        model.select(.rect([10, 10, 5, 3]))
        model.copy()
        let png = try #require(model.clipboard.data(forType: .png))
        #expect(size(ofPNG: png)! == (5, 3), "the clipboard has what was copied, cut to it")

        model.paste()
        let pasted = try #require(model.currentLayer)
        #expect(pasted.id != sprite && pasted.name == "Pasted" && doc.state.layers.count == 2)
        #expect(doc.lift(pasted.id)?.rect == CGRect(x: 10, y: 10, width: 5, height: 3), "where it was")

        // Another app's picture on the clipboard: brought in, in the middle.
        let other = try CanvasDocument.create(width: 4, height: 4, preset: .pixel, at: model.folder.appending(path: "other.canvas"))
        other.apply(.fillRect(layer: other.state.layers[0].id, x: 0, y: 0, width: 4, height: 4, color: red), label: "Fill")
        model.clipboard.clearContents()
        model.clipboard.setData(try other.png(), forType: .png)
        model.selectNothing()
        model.paste()
        let brought = try #require(model.currentLayer)
        #expect(doc.state.layers.count == 3 && doc.state.layers.last?.id == brought.id && brought.name == "Pasted")
        #expect(doc.lift(brought.id)?.rect == CGRect(x: 30, y: 30, width: 4, height: 4))
        model.undo()
        #expect(doc.state.layers.count == 2, "one step")

        // Cut: gone from the layer it came from.
        model.layer = sprite
        model.copy(cut: true)
        #expect(doc.lift(sprite) == nil && doc.state.undo == "Cut")
    }

    @Test func cropTurnAndTheKeys() throws {
        let model = try model()
        let doc = try #require(model.document)
        model.cropToSelection()
        #expect(model.notice == "Select something to crop to.")
        model.select(.rect([2, 3, 10, 5]))
        model.cropToSelection()
        #expect(doc.width == 10 && doc.height == 5 && doc.state.undo == "Crop")
        model.turn(quarters: 1)
        #expect(doc.width == 5 && doc.height == 10)

        #expect(model.handleKey(key("s")) && model.tool == .select && model.selectShape == .rect)
        #expect(model.handleKey(key("s")) && model.selectShape == .ellipse, "s again, the next shape")
        #expect(model.handleKey(key("w")) && model.tool == .wand)
        #expect(model.handleKey(key("v")) && model.tool == .move)
        #expect(!model.startTransform(free: false) && model.notice?.hasPrefix("There’s nothing") == true)

        let sprite = try #require(model.currentLayer).id
        model.change(.fillRect(layer: sprite, x: 0, y: 0, width: 5, height: 10, color: red), label: "Fill")
        model.selectNothing()
        #expect(model.handleKey(key("\u{7f}", code: 51)) && doc.state.undo == "Clear" && doc.lift(sprite) == nil, "⌫ clears all of it")
    }
}
