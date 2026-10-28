import Foundation
import ImageIO
import Testing
@testable import CanvasCore
@testable import CanvasUI

@MainActor
struct CanvasMakeTests {
    private let red = RGBA(220, 40, 40)

    private func model(_ width: Int = 32, _ height: Int = 32) throws -> CanvasWorkspaceModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-canvases-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = CanvasWorkspaceModel(folder: folder, defaults: UserDefaults(suiteName: "aether-tests-\(UUID().uuidString)")!)
        model.stageSize = CGSize(width: 1400, height: 900)
        model.newCanvas(named: "Make", preset: .pixel, width: width, height: height)
        model.color = red
        return model
    }

    private func drawn(_ doc: CanvasDocument) -> Int {
        (0..<doc.height).reduce(0) { n, y in n + (0..<doc.width).filter { doc.pick(x: $0, y: y)?.a ?? 0 > 0 }.count }
    }

    private func size(ofPNG data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    @Test func aGeneratorIsShownThenKeptAsOneEditOrLeft() throws {
        let model = try model()
        let doc = try #require(model.document)
        model.make.generator.what = .sprite
        model.make.generator.seed = 7
        model.showMade(.generator)
        #expect(model.making?.label == "Sprite" && drawn(doc) > 0, "shown")
        #expect(doc.state.undo == nil, "and not kept")
        model.leaveMade()
        #expect(model.making == nil && drawn(doc) == 0, "left: as it was")

        model.showMade(.generator)
        let shown = drawn(doc)
        model.keepMade(.generator)
        #expect(model.making == nil && drawn(doc) == shown && doc.state.undo == "Sprite", "kept as shown, one edit")
        model.undo()
        #expect(drawn(doc) == 0)

        // Noise fills the canvas; held to what is selected, only that.
        model.make.generator.what = .noise
        model.make.generator.cell = 4
        model.keepMade(.generator)
        #expect(drawn(doc) == 32 * 32 && doc.state.undo == "Noise")
        model.undo()
        model.select(.rect([4, 4, 8, 8]))
        model.make.generator.what = .cave
        model.make.generator.density = 60
        model.keepMade(.generator)
        let caves = drawn(doc)
        #expect(caves > 0 && caves <= 64 && doc.pick(x: 20, y: 20)?.a ?? 0 == 0, "caves, inside the selection")
    }

    @Test func filtersMakeTheLayerOver() throws {
        let model = try model()
        let doc = try #require(model.document)
        let sprite = try #require(model.currentLayer).id
        model.change(.fillRect(layer: sprite, x: 10, y: 10, width: 6, height: 6, color: red), label: "Fill")
        model.color = RGBA(0, 0, 0)
        model.make.filter.kind = .outline
        model.keepMade(.filter)
        #expect(doc.pick(x: 9, y: 12) == RGBA(0, 0, 0) && doc.pick(x: 12, y: 12) == red && doc.state.undo == "Outline", "a line round it")
        model.undo()

        model.make.filter.kind = .shadow
        model.make.filter.dx = 3
        model.make.filter.dy = 3
        model.make.filter.shade = 100
        model.keepMade(.filter)
        #expect(doc.pick(x: 18, y: 18)?.a ?? 0 > 0 && doc.pick(x: 12, y: 12) == red, "cast off, under it")
        model.undo()

        model.make.filter.kind = .quantize
        model.make.filter.count = 2
        model.make.filter.keep = true
        model.keepMade(.filter)
        #expect(doc.state.palette.count <= 2 && doc.state.undo == "Fewer colours", "kept as the palette")
    }

    @Test func aCanvasGrowsBy2xAnd3x() throws {
        let model = try model(16, 8)
        let doc = try #require(model.document)
        model.grow(by: 2)
        #expect(doc.width == 32 && doc.height == 16 && doc.state.undo == "Grow ×2")
        model.grow(by: 3)
        #expect(doc.width == 96 && doc.height == 48)
        model.undo()
        #expect(doc.width == 32)
        let big = try self.model(512, 512)
        big.grow(by: 3)
        #expect(big.document?.width == 512 && big.notice != nil, "past a pixel canvas's most: refused, and said")
    }

    @Test func itIsWrittenOutAsAPNGASheetOrPhotoshop() throws {
        let model = try model(8, 4)
        model.export.scale = 4
        let png = try model.exportFiles(model.export, name: "hero")
        #expect(png.map(\.name) == ["hero.png"] && size(ofPNG: png[0].data)! == (32, 16))

        model.addFrame()
        model.addFrame()
        model.export.format = .sheet
        model.export.scale = 1
        let grid = try model.exportFiles(model.export, name: "hero")
        #expect(grid.map(\.name) == ["hero.png", "hero.json"] && size(ofPNG: grid[0].data)! == (16, 8), "three frames, two to a row")
        let json = try JSONSerialization.jsonObject(with: grid[1].data) as? [String: Any]
        #expect((json?["frames"] as? [Any])?.count == 3 && (json?["meta"] as? [String: Any])?["image"] as? String == "hero.png")
        model.export.inRow = true
        #expect(size(ofPNG: try model.exportFiles(model.export, name: "hero")[0].data)! == (24, 4), "in a row")

        // What the Make panel shows, not kept, isn't written out.
        model.export = CanvasExportSettings()
        let plain = try model.exportFiles(model.export, name: "hero")[0].data
        model.make.generator.what = .noise
        model.showMade(.generator)
        #expect(try model.exportFiles(model.export, name: "hero")[0].data == plain && model.making == nil)

        model.export.format = .psd
        let psd = try model.exportFiles(model.export, name: "hero")
        #expect(psd.map(\.name) == ["hero.psd"] && psd[0].data.prefix(4) == Data("8BPS".utf8))
    }

    @Test func anEditLetsGoOfWhatIsShown() throws {
        let model = try model()
        model.make.generator.what = .sprite
        model.showMade(.generator)
        #expect(model.making != nil)
        model.addLayer()
        #expect(model.making == nil && model.document?.state.undo == "Add a layer")
    }
}
