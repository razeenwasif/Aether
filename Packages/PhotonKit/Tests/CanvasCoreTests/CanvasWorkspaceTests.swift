import AppKit
import Foundation
import Testing
@testable import CanvasCore
@testable import CanvasUI

@MainActor
struct CanvasWorkspaceTests {
    private func model() throws -> CanvasWorkspaceModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-canvases-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = CanvasWorkspaceModel(folder: folder, defaults: UserDefaults(suiteName: "photon-tests-\(UUID().uuidString)")!)
        model.stageSize = CGSize(width: 1400, height: 900)
        return model
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @Test func aNewCanvasIsWrittenListedAndNamedApart() throws {
        let model = try model()
        model.newCanvas(named: "Hero", preset: .pixel, width: 64, height: 64)
        let first = try #require(model.document)
        #expect(first.name == "Hero" && model.canvases.map(\.name) == ["Hero"] && model.tool == .pencil)
        #expect(model.viewport.scale == model.viewport.scale.rounded(), "a pixel canvas fits at whole pixels")

        model.newCanvas(named: "Hero", preset: .paint, width: 1024, height: 1024)
        #expect(model.document?.name == "Hero 2" && model.canvases.count == 2 && model.tool == .brush)
        #expect(model.currentLayer?.name == "Background")

        model.newCanvas(named: "Hero\n", preset: .pixel, width: 16, height: 16)
        #expect(model.document?.name == "Hero 3", "a name is one line")
    }

    @Test func aPictureSentPlainIsKeptAndASealedOneIsNot() throws {
        let model = try model()
        let source = try CanvasDocument.create(width: 40, height: 30, preset: .pixel, at: model.folder.appending(path: "x.canvas"))
        source.apply(.fillRect(layer: source.state.layers[0].id, x: 0, y: 0, width: 40, height: 30, color: RGBA(10, 20, 30)), label: "Fill")
        let png = try source.png()

        model.receive(png, named: "image_0001.png", keep: true)
        #expect(model.document?.name == "image_0001" && model.document?.state.dirty == false)
        #expect(model.canvases.map(\.name) == ["image_0001"] && model.notice == nil)

        model.receive(png, named: "image_0002.png", keep: false)
        let sealed = try #require(model.document)
        #expect(sealed.name == "image_0002" && sealed.state.dirty)
        #expect(!FileManager.default.fileExists(atPath: sealed.url.path), "a sealed picture isn't written plain until saved")
        #expect(model.notice?.contains("saved plain") == true)
        #expect(sealed.pixels.pixel(x: 3, y: 3) == [10, 20, 30, 255])
    }

    @Test func leavingWithChangesAsksFirst() throws {
        let model = try model()
        model.newCanvas(named: "One", preset: .pixel, width: 32, height: 32)
        let one = try #require(model.document)
        model.change(.fillRect(layer: one.state.layers[0].id, x: 0, y: 0, width: 4, height: 4, color: RGBA(1, 1, 1)), label: "Fill")
        model.newCanvas(named: "Two", preset: .pixel, width: 32, height: 32)
        #expect(model.leaving != nil && model.document === one, "it asks before leaving")
        model.answerLeaving(save: nil)
        #expect(model.leaving == nil && model.document === one, "Stay stays")

        model.close()
        model.answerLeaving(save: true)
        let reopened = try CanvasDocument.open(one.url)
        #expect(model.document == nil && !reopened.state.dirty, "Save and leave saves")
        #expect(try CanvasDocument.open(one.url).pick(x: 1, y: 1) == RGBA(1, 1, 1))
    }

    @Test func keysChooseToolsAndSizes() throws {
        let model = try model()
        #expect(!model.handleKey(key("e")), "no canvas, no keys")
        model.newCanvas(named: "Keys", preset: .pixel, width: 16, height: 16)
        #expect(model.handleKey(key("b")) && model.tool == .pencil)
        #expect(model.handleKey(key("n")) && model.tool == .brush)
        #expect(model.handleKey(key("g")) && model.tool == .fill)
        #expect(model.handleKey(key("r")) && model.tool == .rect)
        model.tool = .pencil
        #expect(model.handleKey(key("]")) && model.tip.size == 2)
        #expect(!model.handleKey(key("s", .command)), "⌘S is the menu's")
        let scale = model.viewport.scale
        #expect(model.handleKey(key("1")) && model.viewport.scale == 1)
        #expect(model.handleKey(key("f")) && model.viewport.scale == scale)
        #expect(model.handleKey(key(" ")) && model.panning)
    }

    @Test func layersAreAddedAboveAndRemovedWithTheOneBelowChosen() throws {
        let model = try model()
        model.newCanvas(named: "Layers", preset: .pixel, width: 16, height: 16)
        model.addLayer()
        model.addLayer()
        let names = model.document?.state.layers.map(\.name)
        #expect(names == ["Sprite", "Layer 2", "Layer 3"] && model.currentLayer?.name == "Layer 3")
        model.layer = model.document?.state.layers[1].id
        model.moveLayer(up: true)
        #expect(model.document?.state.layers.map(\.name) == ["Sprite", "Layer 3", "Layer 2"] && model.currentLayer?.name == "Layer 2")
        model.removeLayer()
        #expect(model.document?.state.layers.map(\.name) == ["Sprite", "Layer 3"] && model.currentLayer?.name == "Layer 3")
    }
}
