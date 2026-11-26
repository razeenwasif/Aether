import PhotonGraph
import Foundation
import Testing
@testable import CanvasCore
@testable import CanvasUI

@MainActor
struct CanvasLinkTests {
    private let red = RGBA(255, 0, 0)
    private let blue = RGBA(0, 0, 255)
    private let green = RGBA(0, 255, 0)

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "photon-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "Canvases"), withIntermediateDirectories: true)
        return folder
    }

    private func model(_ project: ProjectGraph, in folder: URL) -> CanvasWorkspaceModel {
        let model = CanvasWorkspaceModel(folder: folder.appending(path: "Canvases", directoryHint: .isDirectory), defaults: UserDefaults(suiteName: "photon-tests-\(UUID().uuidString)")!)
        model.stageSize = CGSize(width: 1400, height: 900)
        model.project = project
        return model
    }

    /// A picture `side` a side of one colour, as a PNG.
    private func png(_ color: RGBA, side: Int = 8) throws -> Data {
        let doc = try CanvasDocument.create(width: side, height: side, preset: .pixel, at: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).canvas"))
        doc.apply(.fillRect(layer: doc.state.layers[0].id, x: 0, y: 0, width: Int32(side), height: Int32(side), color: color), label: "Fill")
        return try doc.png()
    }

    private func publish(_ project: ProjectGraph, _ asset: AssetID, _ data: Data) async throws {
        try project.publish(asset, blob: try await project.pool.store(data), width: 8, height: 8)
    }

    @Test func aPlacedAssetIsALayerThatFollowsIt() async throws {
        let project = ProjectGraph(folder: nil)
        let model = model(project, in: try folder())
        model.newCanvas(named: "Scene", preset: .pixel, width: 8, height: 8)
        let doc = try #require(model.document)
        let art = try project.asset(madeBy: "Flows/key.flow.json", named: "Key art", in: .diffuse)
        try await publish(project, art.id, png(red))

        model.place(try #require(project.asset(art.id)))
        await model.following?.value
        let layer = try #require(model.currentLayer)
        #expect(layer.name == "Key art" && doc.state.layers.count == 2 && doc.pick(x: 1, y: 1) == red)
        #expect(model.link(of: layer)?.shown == 1 && model.undoLabel == "Bring in Key art")
        #expect(model.linkedRefusal(layer)?.contains("unlink it") == true, "not painted on while it follows")

        // A newer version: the layer takes it, one step.
        try await publish(project, art.id, png(blue))
        await model.following?.value
        #expect(doc.pick(x: 1, y: 1) == blue && model.undoLabel == "Update Key art to v2")

        // Keep v1: shown at once, the picture and the pin one step.
        model.keep(1, for: try #require(model.link(of: layer)))
        await model.following?.value
        #expect(doc.pick(x: 1, y: 1) == red && model.link(of: layer)?.pinned == 1 && model.undoLabel == "Update Key art to v1")
        try await publish(project, art.id, png(green))
        await model.following?.value
        #expect(doc.pick(x: 1, y: 1) == red, "kept, whatever comes next")

        model.undo()
        #expect(doc.pick(x: 1, y: 1) == blue && model.link(of: layer)?.pinned == nil, "the pin and its picture went back together")
        #expect(model.link(of: layer)?.shown == 2, "and which version it shows")
        model.undo()
        #expect(doc.pick(x: 1, y: 1) == red && model.link(of: layer)?.shown == 1, "undo put v1 back: the link says so")
        model.takeNewest(try #require(model.link(of: layer)))
        await model.following?.value
        #expect(doc.pick(x: 1, y: 1) == green && model.link(of: layer)?.shown == 3)
        model.undo()
        model.undo()
        #expect(doc.state.layers.count == 1 && project.links.isEmpty, "the layer and its link went back together")
        model.redo()
        #expect(doc.state.layers.count == 2 && project.links.count == 1)

        // A project step drops the canvas's redo, though its core keeps it.
        model.undo()
        #expect(doc.state.layers.count == 1 && model.redoLabel == "Bring in Key art")
        model.redo()
        model.unlink(project.links[0])
        #expect(model.redoLabel == nil && doc.state.redo != nil)
        model.redo()
        #expect(project.links.isEmpty, "nothing redone behind the history's back")
        model.undo()
        model.redo()
        let current = try #require(model.currentLayer)
        #expect(project.links.isEmpty && model.linkedRefusal(current) == nil && model.undoLabel == "Unlink")
        model.undo()
        #expect(project.links.count == 1, "unlinking is a step in the canvas")
    }

    @Test func aPictureSentInFollowsAndCatchesUpWhenOpenedAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = ProjectGraph(folder: folder)
        let model = model(project, in: folder)
        let art = try project.asset(madeBy: "Flows/key.flow.json", named: "Key art", in: .diffuse)
        try await publish(project, art.id, png(red))

        model.receive(try png(red), named: "key art_0001.png", keep: true, linking: project.asset(art.id))
        let url = try #require(model.document).url
        #expect(model.documentPath == "Canvases/key art_0001.canvas")
        let layer = try #require(model.document?.state.layers.first)
        #expect(project.links(in: "Canvases/key art_0001.canvas").map(\.slot) == [Slot.layer(layer.id)])
        #expect(model.undoLabel == nil, "linked as it was made, not a step")

        // Shut, it misses v2; opened again, it takes it.
        model.close()
        try await publish(project, art.id, png(blue))
        #expect(model.following == nil || model.document == nil)
        model.open(url)
        await model.following?.value
        #expect(model.document?.pick(x: 1, y: 1) == blue)
        #expect(project.links[0].shown == 2)
    }

    @Test func aCanvasUsedElsewhereIsPublishedWhenSaved() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = ProjectGraph(folder: folder)
        let model = model(project, in: folder)
        model.newCanvas(named: "Sky", preset: .pixel, width: 8, height: 8)
        let doc = try #require(model.document)
        let asset = try await model.asset(ofCanvasAt: doc.url)
        #expect(asset.source == .canvas && asset.name == "Sky" && asset.document == "Canvases/Sky.canvas" && asset.versions.count == 1)
        #expect(model.usedBy.isEmpty)
        try project.apply(Transaction([project.linkOp(asset.id, into: "Flows/f.flow.json", slot: Slot.input(node: "3", field: "image"), by: .diffuse)], origin: .diffuse, label: "Link"))
        #expect(model.usedBy.count == 1)

        model.change(.fillRect(layer: doc.state.layers[0].id, x: 0, y: 0, width: 8, height: 8, color: red), label: "Fill")
        model.save()
        await model.publishing?.value
        #expect(project.asset(asset.id)?.versions.map(\.note) == ["saved", "saved"])
        model.save()
        await model.publishing?.value
        #expect(project.asset(asset.id)?.versions.count == 2, "nothing new, no version")

        // Saved elsewhere: its asset goes with it.
        try doc.save(as: folder.appending(path: "Canvases/Sky 2.canvas"))
        project.move(document: "Canvases/Sky.canvas", to: project.path(of: doc.url), by: .canvas)
        #expect(project.asset(asset.id)?.document == "Canvases/Sky 2.canvas")
    }

    @Test func aLinkNotSavedWithItsCanvasGoesWhenTheCanvasIsShut() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = ProjectGraph(folder: folder)
        let model = model(project, in: folder)
        model.newCanvas(named: "Scene", preset: .pixel, width: 8, height: 8)
        let url = try #require(model.document).url
        let art = try project.asset(madeBy: "Flows/key.flow.json", named: "Key art", in: .diffuse)
        try await publish(project, art.id, png(red))

        model.place(try #require(project.asset(art.id)))
        await model.following?.value
        let placed = try #require(model.currentLayer).id
        model.close()
        model.answerLeaving(save: false)
        #expect(project.links.isEmpty, "never saved with the canvas")
        // Reopened, the next layer made gets that id, and follows nothing.
        model.open(url)
        model.addLayer()
        let next = try #require(model.currentLayer)
        #expect(next.id == placed && model.link(of: next) == nil)

        // Saved with it, it stays.
        model.place(try #require(project.asset(art.id)))
        await model.following?.value
        model.save()
        model.close()
        #expect(project.links.count == 1)
    }

    @Test func everyCanvasStepIsInTheProjectsHistory() throws {
        let project = ProjectGraph(folder: nil)
        let model = model(project, in: try folder())
        model.newCanvas(named: "Steps", preset: .pixel, width: 8, height: 8)
        let doc = try #require(model.document)
        let path = try #require(model.documentPath)
        model.change(.fillRect(layer: doc.state.layers[0].id, x: 0, y: 0, width: 2, height: 2, color: red), label: "Fill")
        model.addLayer()
        #expect(project.history.done.map(\.label) == ["Fill", "Add a layer"] && project.undoLabel(in: path) == "Add a layer")
        model.undo()
        #expect(doc.state.layers.count == 1 && project.redoLabel(in: path) == "Add a layer")
        model.close()
        model.answerLeaving(save: false)
        #expect(project.history.done.isEmpty && project.history.undone.isEmpty, "shut, its steps leave with it")
    }
}
