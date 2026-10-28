import AppKit
import Foundation
import Testing
@testable import CanvasCore
@testable import CanvasUI

@MainActor
struct CanvasPaletteTests {
    private func model(_ preset: CanvasPreset = .pixel, size: Int = 64) throws -> CanvasWorkspaceModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-canvases-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = CanvasWorkspaceModel(folder: folder)
        model.stageSize = CGSize(width: 1400, height: 900)
        model.newCanvas(named: "Palette", preset: preset, width: size, height: size)
        return model
    }

    private func key(_ characters: String, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @Test func aSwatchRecolouredChangesEveryPixelOfItAsOneEdit() throws {
        let model = try model()
        let doc = try #require(model.document)
        #expect(model.palette.count == 16, "a pixel canvas starts with Proton's sixteen")
        model.chooseSwatch(6)
        let red = model.palette[6]
        #expect(model.color == red && model.swatch == 6 && !model.canRecolour)
        let sprite = try #require(model.currentLayer).id
        model.change(.fillRect(layer: sprite, x: 0, y: 0, width: 8, height: 8, color: red), label: "Fill")

        #expect(model.setColor(hex: "#123456"))
        #expect(model.canRecolour)
        model.recolourSwatch()
        #expect(doc.state.undo == "Recolour" && model.palette[6] == RGBA(0x12, 0x34, 0x56))
        #expect(doc.pick(x: 3, y: 3) == RGBA(0x12, 0x34, 0x56), "every pixel of it")
        model.undo()
        #expect(model.palette[6] == red && doc.pick(x: 3, y: 3) == red, "one step back, both")
    }

    @Test func coloursAreAddedRampedAndRemoved() throws {
        let model = try model(.paint, size: 1024)
        #expect(model.palette.isEmpty, "a painting starts with none")
        model.setColor(hex: "3e9e5c")
        model.addToPalette()
        #expect(model.palette == [RGBA(0x3e, 0x9e, 0x5c)] && model.swatch == 0)
        model.addToPalette()
        #expect(model.palette.count == 1, "once")
        model.addRamp()
        let lights = model.palette.dropFirst().map { Int($0.r) + Int($0.g) + Int($0.b) }
        #expect(model.palette.count >= 5 && model.palette.count <= 6 && lights == lights.sorted(), "darkest first")
        model.removeFromPalette()
        #expect(!model.palette.contains(RGBA(0x3e, 0x9e, 0x5c)) && model.swatch == nil)
    }

    @Test func hexCodesAreReadThreeSixOrEightLong() throws {
        let model = try model()
        #expect(model.setColor(hex: "#abc") && model.color == RGBA(0xaa, 0xbb, 0xcc))
        #expect(model.setColor(hex: " a1b2c3 ") && model.color == RGBA(0xa1, 0xb2, 0xc3))
        #expect(model.setColor(hex: "#a1b2c380") && model.color == RGBA(0xa1, 0xb2, 0xc3, 0x80) && model.color.hex == "#a1b2c380")
        #expect(!model.setColor(hex: "#ggg") && !model.setColor(hex: "12345") && model.color == RGBA(0xa1, 0xb2, 0xc3, 0x80))
    }

    @Test func mirroredDrawingAndTheGridAreKeys() throws {
        let model = try model()
        let doc = try #require(model.document)
        #expect(model.handleKey(key("m")) && model.mirrorAcross && !model.mirrorDown)
        #expect(model.handleKey(key("M", shift: true)) && model.mirrorDown)
        #expect(model.drawingTip.mirror == [64, 64] && model.tip.mirror == [nil, nil], "twice the place: the middle")
        #expect(model.handleKey(key("G", shift: true)) && model.showGrid && model.tool != .fill)
        #expect(model.handleKey(key("g")) && model.tool == .fill)

        let sprite = try #require(model.currentLayer).id
        model.color = RGBA(255, 0, 0)
        #expect(doc.beginStroke(StrokeBegin(layer: sprite, tool: .pencil, tip: model.drawingTip, color: model.color)))
        doc.addToStroke([(2.5, 3.5, 1)])
        doc.endStroke(label: "Pencil")
        for (x, y) in [(2, 3), (61, 3), (2, 60), (61, 60)] {
            #expect(doc.pick(x: x, y: y) == RGBA(255, 0, 0), "mirrored to \(x), \(y)")
        }
        model.mirrorDown = false
        model.change(.shape(layer: sprite, kind: .line, from: [10, 20], to: [12, 20], tip: model.drawingTip, color: RGBA(0, 0, 255)), label: "Line")
        #expect(doc.pick(x: 53, y: 20) == RGBA(0, 0, 255) && doc.pick(x: 53, y: 43)?.a ?? 0 == 0, "shapes too, across only")
    }

    @Test func theCanvasIsResizedAsOneStepWithinItsPreset() throws {
        let model = try model()
        let doc = try #require(model.document)
        model.resizeCanvas(width: 32, height: 16)
        #expect(doc.width == 32 && doc.height == 16 && doc.state.undo == "Resize")
        model.resizeCanvas(width: 2000, height: 16)
        #expect(doc.width == 32 && model.notice == "A Pixel canvas is 1 to 1024 pixels a side.")
        model.undo()
        #expect(doc.width == 64 && doc.height == 64)
    }
}
