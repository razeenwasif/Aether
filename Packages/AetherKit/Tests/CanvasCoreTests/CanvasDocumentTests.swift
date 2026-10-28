import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct CanvasDocumentTests {
    private func scratch(_ name: String = "Test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-canvas-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(name).canvas", directoryHint: .isDirectory)
    }

    @Test func aFilledRectShowsAcrossTilesAndUndoesAsOneStep() throws {
        let doc = try CanvasDocument.create(width: 100, height: 70, preset: .pixel, at: try scratch())
        #expect(doc.state.layers.map(\.name) == ["Sprite"] && !doc.state.dirty && !doc.state.canUndo)
        _ = doc.pixels.takeChanged()
        let layer = doc.state.layers[0].id
        #expect(doc.apply(.fillRect(layer: layer, x: 10, y: 10, width: 60, height: 50, color: RGBA(255, 0, 0)), label: "Fill") != nil)
        #expect(doc.pixels.pixel(x: 65, y: 12) == [255, 0, 0, 255], "the fill runs over the tile edge at 64")
        #expect(doc.pixels.pixel(x: 5, y: 5) == [0, 0, 0, 0])
        #expect(doc.pixels.takeChanged() == [0, 1], "only the two tiles it covers are made again")
        #expect(doc.state.dirty && doc.state.undo == "Fill")
        doc.undo()
        #expect(doc.pixels.pixel(x: 65, y: 12) == [0, 0, 0, 0])
        #expect(doc.state.canRedo && !doc.state.canUndo)
    }

    @Test func aStrokeIsDrawnAsThePenMovesAndKeptAsOneStep() throws {
        let doc = try CanvasDocument.create(width: 256, height: 256, preset: .paint, at: try scratch())
        let layer = doc.state.layers[0].id
        #expect(doc.beginStroke(StrokeBegin(layer: layer, tool: .pencil, brush: CanvasBrush(size: 12, hardness: 100), color: RGBA(0, 0, 255))))
        doc.addToStroke([(20, 20, 1), (120, 20, 1)])
        #expect(doc.pixels.pixel(x: 70, y: 20)[2] > 200, "painted before the stroke ends")
        #expect(!doc.state.canUndo)
        doc.addToStroke([(120, 120, 0.5)])
        doc.endStroke(label: "Brush")
        #expect(doc.state.undo == "Brush" && doc.pixels.pixel(x: 70, y: 20)[2] > 200)
        doc.undo()
        #expect(doc.pixels.pixel(x: 70, y: 20) == [0, 0, 0, 0] && !doc.state.canUndo, "the whole stroke was one step")
    }

    @Test func aCancelledStrokeAndAPreviewLeaveNothing() throws {
        let doc = try CanvasDocument.create(width: 64, height: 64, preset: .pixel, at: try scratch())
        let layer = doc.state.layers[0].id
        #expect(doc.beginStroke(StrokeBegin(layer: layer, tool: .pencil, tip: CanvasTip(size: 1), color: RGBA(9, 9, 9))))
        doc.addToStroke([(2.5, 2.5, 1), (10.5, 2.5, 1)])
        #expect(doc.pixels.pixel(x: 5, y: 2) == [9, 9, 9, 255])
        doc.cancelStroke()
        #expect(doc.pixels.pixel(x: 5, y: 2) == [0, 0, 0, 0] && !doc.state.canUndo)

        doc.preview(.shape(layer: layer, kind: .rect, from: [4, 4], to: [20, 20], filled: true, tip: CanvasTip(size: 1), color: RGBA(0, 200, 0)))
        #expect(doc.pixels.pixel(x: 10, y: 10) == [0, 200, 0, 255])
        doc.clearPreview()
        #expect(doc.pixels.pixel(x: 10, y: 10) == [0, 0, 0, 0] && !doc.state.canUndo)
    }

    @Test func layersChangeWhatShows() throws {
        let doc = try CanvasDocument.create(width: 32, height: 32, preset: .pixel, at: try scratch())
        let bottom = doc.state.layers[0].id
        doc.apply(.fillRect(layer: bottom, x: 0, y: 0, width: 32, height: 32, color: RGBA(255, 255, 255)), label: "Fill")
        let made = try #require(doc.apply(.addLayer(name: "Ink"), label: "Add layer")?.made)
        doc.apply(.fill(layer: made, x: 3, y: 3, color: RGBA(0, 0, 0)), label: "Fill")
        #expect(doc.pick(x: 3, y: 3) == RGBA(0, 0, 0))
        doc.apply(.setLayer(made, hidden: true), label: "Hide")
        #expect(doc.pick(x: 3, y: 3) == RGBA(255, 255, 255) && doc.pixels.pixel(x: 3, y: 3) == [255, 255, 255, 255])
        doc.apply(.setLayer(made, opacity: 128, hidden: false), label: "Opacity")
        #expect((120...135).contains(Int(doc.pixels.pixel(x: 3, y: 3)[0])), "half black over white")
        #expect(doc.state.layers.map(\.name) == ["Sprite", "Ink"])
        doc.apply(.moveLayer(made, to: 0), label: "Move")
        #expect(doc.state.layers.map(\.name) == ["Ink", "Sprite"] && doc.pick(x: 3, y: 3) == RGBA(255, 255, 255))
    }

    @Test func aRefusedChangeSaysWhy() throws {
        let doc = try CanvasDocument.create(width: 16, height: 16, preset: .pixel, at: try scratch())
        #expect(doc.apply(.removeLayer(999), label: "Remove") == nil)
        #expect(doc.refusal != nil)
        doc.apply(.setLayer(doc.state.layers[0].id, locked: true), label: "Lock")
        #expect(!doc.beginStroke(StrokeBegin(layer: doc.state.layers[0].id, tool: .pencil, tip: CanvasTip(), color: RGBA(1, 2, 3))))
        #expect(doc.refusal?.contains("locked") == true)
    }

    @Test func itSavesReopensAndImportsAPicture() throws {
        let url = try scratch("Saved")
        let doc = try CanvasDocument.create(width: 80, height: 40, preset: .pixel, at: url)
        doc.apply(.fillRect(layer: doc.state.layers[0].id, x: 70, y: 30, width: 10, height: 10, color: RGBA(1, 2, 3)), label: "Fill")
        try doc.save()
        #expect(!doc.state.dirty)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "canvas.json").path))

        let again = try CanvasDocument.open(url)
        #expect(again.name == "Saved" && again.width == 80 && again.pixels.pixel(x: 75, y: 35) == [1, 2, 3, 255] && !again.state.dirty)

        let picture = try CanvasDocument.importing(try doc.png(), named: "picture.png", at: try scratch("Picture"))
        #expect(picture.width == 80 && picture.height == 40 && picture.pixels.pixel(x: 75, y: 35) == [1, 2, 3, 255])
        #expect(picture.state.dirty, "an imported picture isn't saved until it is")
    }
}
