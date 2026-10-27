import DiffuseBridge
import Foundation
import Testing
@testable import DiffuseCore

struct MaskTests {
    @Test func aDabIsSolidInsideAndFadesToItsEdge() {
        var mask = MaskDocument(width: 64, height: 64)
        mask.beginStroke()
        mask.dab(at: CGPoint(x: 32, y: 32), size: 40, softness: 0.5, erase: false)
        let at = { (x: Int, y: Int) in mask.coverage[y * 64 + x] }
        #expect(at(32, 32) == 255)
        #expect(at(32 + 5, 32) == 255, "inside the solid half of the radius")
        #expect(at(32 + 16, 32) > 0 && at(32 + 16, 32) < 255, "fading")
        #expect(at(32 + 21, 32) == 0 && at(0, 0) == 0, "outside the brush")

        var hard = MaskDocument(width: 64, height: 64)
        hard.dab(at: CGPoint(x: 32, y: 32), size: 40, softness: 0, erase: false)
        #expect(hard.coverage[32 * 64 + 32 + 19] == 255)
    }

    @Test func theEraserTakesPaintAwayAndUndoPutsItBack() {
        var mask = MaskDocument(width: 32, height: 32)
        mask.beginStroke()
        mask.dab(at: CGPoint(x: 16, y: 16), size: 20, softness: 0, erase: false)
        let painted = mask.coverage
        mask.beginStroke()
        mask.dab(at: CGPoint(x: 16, y: 16), size: 10, softness: 0, erase: true)
        #expect(mask.coverage[16 * 32 + 16] == 0 && mask.coverage[16 * 32 + 16 + 8] == 255)
        mask.undo()
        #expect(mask.coverage == painted)
        mask.undo()
        #expect(mask.share == 0 && !mask.canUndo)
    }

    @Test func aLineIsDabsAlongThePath() {
        var mask = MaskDocument(width: 100, height: 20)
        mask.dab(at: CGPoint(x: 10, y: 10), size: 8, softness: 0, erase: false)
        mask.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10), size: 8, softness: 0, erase: false)
        #expect((10...90).allSatisfy { mask.coverage[10 * 100 + $0] == 255 }, "no gaps along the line")
        #expect(mask.coverage[0] == 0)
    }

    @Test func invertClearAndShare() {
        var mask = MaskDocument(width: 10, height: 10)
        #expect(mask.share == 0)
        mask.invert()
        #expect(mask.share == 1)
        mask.clear()
        #expect(mask.share == 0)
        mask.undo()
        #expect(mask.share == 1)
        for _ in 0..<40 { mask.invert() }
        var undone = 0
        while mask.canUndo { mask.undo(); undone += 1 }
        #expect(undone == MaskDocument.undoDepth)
    }

    @Test func aMaskIsKeptAsProtonKeepsItAndReadBack() throws {
        var mask = MaskDocument(width: 48, height: 32)
        mask.dab(at: CGPoint(x: 20, y: 16), size: 18, softness: 0.4, erase: false)
        let png = try mask.pngData()
        let back = try #require(MaskDocument(png: png, width: 48, height: 32))
        #expect(back.coverage == mask.coverage)
        #expect(MaskDocument(png: png, width: 64, height: 32) == nil, "a mask of another size starts again")
        let pixels = try maskFromPng(bytes: png)
        #expect(pixels.width == 48 && pixels.height == 32)
    }

    @Test func aMaskIsKeptBesideTheFlowSealedOrPlain() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-mask-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flow = dir.appending(path: "inpaint.flow.json")
        var mask = MaskDocument(width: 8, height: 8)
        mask.invert()
        #expect(try FlowInputs.readMask(node: "4", flow: flow, key: nil) == nil)

        try FlowInputs.writeMask(mask.pngData(), node: "4", flow: flow, key: nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "inpaint.4.mask.png").path))
        #expect(try FlowInputs.readMask(node: "4", flow: flow, key: nil).flatMap { MaskDocument(png: $0, width: 8, height: 8) }?.share == 1)

        let key = try SealKey(key: Data(repeating: 3, count: 32))
        try FlowInputs.writeMask(mask.pngData(), node: "5", flow: flow, key: key)
        #expect(SealedFiles.isSealed(dir.appending(path: "inpaint.5.mask.png")))
        #expect(throws: DiffuseError.self) { try FlowInputs.readMask(node: "5", flow: flow, key: nil) }
        #expect(try FlowInputs.readMask(node: "5", flow: flow, key: key) != nil)
    }
}
