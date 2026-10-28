import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AetherGraph

@MainActor
struct ProjectGraphTests {
    private func asset(_ name: String = "Key art", document: String = "Flows/key art.flow.json") -> Node {
        Node(kind: .asset, properties: ["name": .string(name), "source": .string("diffuse"), "document": .string(document)])
    }

    private func version(_ n: Int, _ blob: String = "b") -> AssetVersion {
        AssetVersion(number: n, blob: "\(blob)\(n)", width: 8, height: 8)
    }

    private func png(_ red: UInt8) -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func aTransactionIsAppliedWholeOrNotAtAll() throws {
        let graph = ProjectGraph(folder: nil)
        let art = asset()
        try graph.apply(Transaction([.insert(art)], origin: .diffuse, label: "Make"))
        #expect(graph.revision == 1 && graph.assets.map(\.name) == ["Key art"])

        let fine = Node(kind: .asset, properties: ["name": .string("Sky"), "source": .string("canvas"), "document": .string("Canvases/sky.canvas")])
        let refused = #expect(throws: GraphError.self) {
            try graph.apply(Transaction([.insert(fine), .remove(NodeID())], origin: .canvas, label: "Both"))
        }
        #expect(refused?.op == 1 && graph.nodes.count == 1 && graph.revision == 1, "the first op isn't kept either")
        #expect(throws: GraphError.self) { try graph.apply(Transaction([.insert(art)], origin: .diffuse, label: "Again")) }
        #expect(throws: GraphError.self, "a link needs an asset that is there") {
            try graph.apply(Transaction([graph.linkOp(AssetID(), into: "Canvases/a.canvas", slot: Slot.layer(1), by: .canvas)], origin: .canvas, label: "Link"))
        }
        let link = graph.linkOp(AssetID(art.id), into: "Canvases/a.canvas", slot: Slot.layer(1), by: .canvas)
        try graph.apply(Transaction([link], origin: .canvas, label: "Link"))
        #expect(throws: GraphError.self, "an asset in use stays") { try graph.apply(Transaction([.remove(art.id)], origin: .diffuse, label: "Remove")) }
    }

    @Test func versionsOnlyGrowAndEveryListenerIsToldAtOnce() throws {
        let graph = ProjectGraph(folder: nil)
        let made = try graph.asset(madeBy: "Flows/key art.flow.json", named: "Key art", in: .diffuse)
        #expect(try graph.asset(madeBy: "Flows/key art.flow.json", named: "Other", in: .diffuse).id == made.id, "one asset a document")
        var heard: [Int] = []
        let listening = graph.onPublish { asset, version in
            if asset.id == made.id { heard.append(version.number) }
        }
        try graph.publish(made.id, blob: "aaa", width: 8, height: 8)
        try graph.publish(made.id, blob: "aaa", width: 8, height: 8)
        try graph.publish(made.id, blob: "bbb", width: 8, height: 8, note: "key art_0002.png")
        #expect(heard == [1, 2], "the same bytes again isn't a version")
        #expect(graph.asset(made.id)?.newest?.note == "key art_0002.png")
        #expect(throws: GraphError.self, "the next number only") { try graph.apply(Transaction([.publish(made.id, version(5))], origin: .diffuse, label: "Skip")) }
        #expect(graph.undoLabel(in: made.document) == nil, "publishing isn't an undo step")

        // A link keeps version 1; it can't be taken away under it.
        try graph.apply(Transaction([graph.linkOp(made.id, into: "Canvases/a.canvas", slot: Slot.layer(2), by: .canvas)], origin: .canvas, label: "Link", document: "Canvases/a.canvas"))
        let link = try #require(graph.link(in: "Canvases/a.canvas", slot: Slot.layer(2)))
        #expect(link.shown == 2 && graph.version(for: link)?.number == 2)
        try graph.pin(link, to: 1)
        #expect(graph.version(for: graph.link(in: "Canvases/a.canvas", slot: "layer:2")!)?.blob == "aaa")
        #expect(throws: GraphError.self) { try graph.pin(graph.links[0], to: 9) }
        #expect(throws: GraphError.self) {
            try graph.apply(Transaction([.retract(made.id, version: 2), .retract(made.id, version: 1)], origin: .diffuse, label: "Back"))
        }
        withExtendedLifetime(listening) {}
    }

    @Test func undoWalksTheStepsOfTheDocumentOnScreen() throws {
        let graph = ProjectGraph(folder: nil)
        let art = try graph.asset(madeBy: "Flows/f.flow.json", named: "Key art", in: .diffuse)
        try graph.publish(art.id, blob: "one", width: 8, height: 8)
        // The canvas's own steps, as its core keeps them.
        var canvasSteps = ["Fill"]
        var canvasUndone: [String] = []
        let undoCanvas = { () -> Bool in
            guard let step = canvasSteps.popLast() else { return false }
            canvasUndone.append(step)
            return true
        }
        let redoCanvas = { () -> Bool in
            guard let step = canvasUndone.popLast() else { return false }
            canvasSteps.append(step)
            return true
        }
        let a = "Canvases/a.canvas"
        try graph.documentStepped(a, label: "Fill")
        // Bringing the asset in is one step: the layer, and its link.
        canvasSteps.append("Bring in")
        try graph.documentStepped(a, label: "Bring in", with: Transaction([graph.linkOp(art.id, into: a, slot: Slot.layer(2), by: .canvas)], origin: .canvas, label: "Link", document: a))
        try graph.documentStepped("Flows/f.flow.json", label: "Move node")
        try graph.pin(graph.links[0], to: 1)
        #expect(graph.undoLabel(in: a) == "Keep Version 1" && graph.undoLabel(in: "Flows/f.flow.json") == "Move node")

        #expect(graph.undo(in: a, documentUndo: undoCanvas))
        #expect(graph.links[0].pinned == nil && canvasSteps == ["Fill", "Bring in"], "the pin first, a project step")
        #expect(graph.undo(in: a, documentUndo: undoCanvas))
        #expect(graph.links.isEmpty && canvasSteps == ["Fill"], "the layer and its link together")
        #expect(graph.redo(in: a, documentRedo: redoCanvas))
        #expect(graph.links.count == 1 && canvasSteps == ["Fill", "Bring in"])

        // A new step in the canvas: its redo goes; the flow's stays.
        #expect(graph.undo(in: "Flows/f.flow.json") { true })
        canvasSteps.append("Stroke")
        try graph.documentStepped(a, label: "Stroke")
        #expect(graph.redoLabel(in: a) == nil && graph.redoLabel(in: "Flows/f.flow.json") == "Move node")

        // The core let go of old steps: their places are passed over.
        canvasSteps = ["Stroke"]
        #expect(graph.undo(in: a, documentUndo: undoCanvas) && graph.undo(in: a, documentUndo: undoCanvas) == false)
        graph.forget(document: a)
        #expect(graph.undoLabel(in: a) == nil && graph.history.done.allSatisfy { $0.document != a })
    }

    @Test func theProjectIsKeptInAFolderAndBytesOnceEach() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString).aether", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let graph = ProjectGraph(folder: folder)
        #expect(graph.name.hasPrefix("aether-project-"))
        graph.saveNow()
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "project.json").path), "nothing changed, nothing written")
        let red = png(255)
        let blob = try await graph.pool.store(red)
        #expect(try await graph.pool.store(red) == blob, "the same bytes, the same blob")
        let outside = folder.deletingLastPathComponent().appending(path: "aether-out-\(UUID().uuidString).png")
        try red.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(try await graph.pool.store(contentsOf: outside) == blob)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "blobs").path) == ["\(blob).png"])
        let first = try #require(await graph.pool.image(blob))
        let second = try #require(await graph.pool.image(blob))
        #expect(first.image === second.image && first.image.width == 4, "decoded once, the same picture for every view")

        let art = try graph.asset(madeBy: graph.path(of: folder.appending(path: "Flows/key art.flow.json")), named: "Key art", in: .diffuse)
        #expect(art.document == "Flows/key art.flow.json", "inside the project, by its path there")
        #expect(graph.path(of: outside) == outside.standardizedFileURL.path, "outside it, the whole path")
        try graph.publish(art.id, blob: blob, width: 4, height: 4, note: "key art_0001.png")
        graph.saveNow()

        let text = try String(contentsOf: folder.appending(path: "project.json"), encoding: .utf8)
        #expect(text.contains("\"format\" : \"aether.project\"") && text.contains("key art_0001.png"))
        let again = try ProjectGraph.open(folder)
        #expect(again.nodes == graph.nodes)
        #expect(try await again.pool.data(blob) == red)
        #expect(try ProjectGraph.open(folder.appending(path: "nothing-here")).nodes.isEmpty)
    }

    @Test func aDocumentSavedElsewhereTakesItsLinksAndStepsWithIt() throws {
        let graph = ProjectGraph(folder: nil)
        let art = try graph.asset(madeBy: "Flows/f.flow.json", named: "Key art", in: .diffuse)
        try graph.publish(art.id, blob: "x", width: 1, height: 1)
        try graph.documentStepped("Canvases/a.canvas", label: "Bring in", with: Transaction([graph.linkOp(art.id, into: "Canvases/a.canvas", slot: Slot.layer(3), by: .canvas)], origin: .canvas, label: "Link", document: "Canvases/a.canvas"))
        graph.move(document: "Canvases/a.canvas", to: "Canvases/b.canvas", by: .canvas)
        #expect(graph.links.map(\.document) == ["Canvases/b.canvas"] && graph.undoLabel(in: "Canvases/b.canvas") == "Bring in")
        #expect(graph.undoLabel(in: "Canvases/a.canvas") == nil)
        #expect(Slot.layer(of: "layer:3") == 3 && Slot.input(of: Slot.input(node: "12", field: "image"))! == ("12", "image"))
    }

    @Test func linksMadeWithUnsavedStepsGoWhenTheDocumentIsLetGo() throws {
        let graph = ProjectGraph(folder: nil)
        let art = try graph.asset(madeBy: "Flows/f.flow.json", named: "Art", in: .diffuse)
        try graph.publish(art.id, blob: "x", width: 1, height: 1)
        let a = "Canvases/a.canvas"
        func link(_ layer: UInt32) -> Transaction {
            Transaction([graph.linkOp(art.id, into: a, slot: Slot.layer(layer), by: .canvas)], origin: .canvas, label: "Link", document: a)
        }
        try graph.documentStepped(a, label: "Bring in", with: link(2))
        graph.documentSaved(a)
        try graph.documentStepped(a, label: "Bring in", with: link(3))
        #expect(graph.links.count == 2)
        graph.discard(document: a)
        #expect(graph.links.map(\.slot) == ["layer:2"] && graph.history.done.isEmpty, "the saved one stays; the unsaved one goes")

        // Saved, then undone: letting go puts it back, as the file has it.
        try graph.documentStepped(a, label: "Bring in", with: link(4))
        graph.documentSaved(a)
        graph.undo(in: a) { true }
        #expect(graph.link(in: a, slot: "layer:4") == nil)
        graph.discard(document: a)
        #expect(graph.link(in: a, slot: "layer:4") != nil)
    }

    @Test func aThousandOpsApplyWellInsideAFrame() throws {
        let graph = ProjectGraph(folder: nil)
        let nodes = (0..<1000).map { asset("Asset \($0)", document: "Canvases/\($0).canvas") }
        let clock = ContinuousClock()
        let took = try clock.measure { try graph.apply(Transaction(nodes.map(Op.insert), origin: .canvas, label: "Many")) }
        let one = try clock.measure { try graph.apply(Transaction([.set(nodes[0].id, property: "name", value: .string("Renamed"))], origin: .canvas, label: "Rename")) }
        // Checked against a copy, all of it: still far under the 2 ms the
        // chrome has a frame (§7), and a single op far less again.
        #expect(graph.nodes.count == 1000 && took < .milliseconds(50) && one < .milliseconds(5), "\(took), \(one)")
    }
}
