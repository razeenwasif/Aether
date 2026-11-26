import PhotonGraph
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DiffuseCore
@testable import DiffuseUI

@MainActor
struct DiffuseLinkTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "photon-diffuse-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A project, and Diffuse in it, the gateway left alone.
    private func setUp() throws -> (ProjectGraph, DiffuseWorkspaceModel) {
        let project = try ProjectGraph.create(base.appending(path: "P.photon"))
        let model = DiffuseWorkspaceModel(flowsFolder: try #require(project.flowsFolder), defaults: UserDefaults(suiteName: "photon-tests-\(UUID().uuidString)")!, connecting: false)
        model.project = project
        return (project, model)
    }

    private func png(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func aLoadImageFollowsACanvasAsset() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (project, model) = try setUp()
        let editor = try #require(model.editor)
        let (red, blue) = (png(1, 0, 0), png(0, 0, 1))
        let sky = try project.asset(madeBy: "Canvases/Sky.canvas", named: "Sky", in: .canvas)
        try project.publish(sky.id, blob: try await project.pool.store(red), width: 4, height: 4)

        await model.use(try #require(project.asset(sky.id)))
        let file = FlowInputs.file("inputs/Sky.png", flow: editor.url)
        #expect(try Data(contentsOf: file) == red)
        let load = try #require(editor.flow.nodes.first { $0.type == "LoadImage" })
        #expect(load.values["image"] == .string("inputs/Sky.png"))
        #expect(model.link(node: load.id, field: "image")?.shown == 1 && model.undoLabel == "Add a Node", "the node and its link, one step")

        // A new version: the picture follows, flow open or not.
        try project.publish(sky.id, blob: try await project.pool.store(blue), width: 4, height: 4)
        await model.linking?.value
        #expect(try Data(contentsOf: file) == blue && model.link(node: load.id, field: "image")?.shown == 2)

        // Keep v1: the picture goes back; undo, and it follows again.
        model.keep(1, for: try #require(model.link(node: load.id, field: "image")))
        await model.linking?.value
        #expect(try Data(contentsOf: file) == red && model.undoLabel == "Keep Version 1")
        model.undo()
        await model.linking?.value
        #expect(try Data(contentsOf: file) == blue && model.link(node: load.id, field: "image")?.pinned == nil)

        model.undo()
        #expect(!editor.flow.nodes.contains { $0.type == "LoadImage" } && project.links.isEmpty, "undone together")
        model.redo()
        #expect(project.links.count == 1)
        model.unlink(project.links[0])
        #expect(project.links.isEmpty && model.undoLabel == "Unlink")
    }

    @Test func aLinkNotSavedWithItsFlowGoesWhenTheFlowIsLetGo() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (project, model) = try setUp()
        let sky = try project.asset(madeBy: "Canvases/Sky.canvas", named: "Sky", in: .canvas)
        try project.publish(sky.id, blob: try await project.pool.store(png(1, 0, 0)), width: 4, height: 4)
        await model.use(try #require(project.asset(sky.id)))
        #expect(project.links.count == 1)
        model.newFlow(template: nil)
        #expect(project.links.isEmpty, "the flow was let go unsaved, and its link with it")

        await model.use(try #require(project.asset(sky.id)))
        model.save()
        model.newFlow(template: nil)
        #expect(project.links.count == 1, "saved with its flow, it stays")
    }

    @Test func aFinishedRunAndSendToCanvasPublishTheFlowsPicture() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (project, model) = try setUp()
        let editor = try #require(model.editor)
        try editor.save()
        let outputs = model.flowsFolder.appending(path: "outputs/\(editor.name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let (red, blue) = (png(1, 0, 0), png(0, 0, 1))
        let first = outputs.appending(path: "image_0001.png")
        try red.write(to: first)

        // Sent to the Canvas: the flow becomes an asset, the picture its v1.
        let sent = try #require(await model.publishForCanvas(GalleryPicture(url: first, flow: editor.name, modified: .now), bytes: red))
        #expect(sent.source == .diffuse && sent.name == editor.name && sent.document == project.path(of: editor.url))
        #expect(sent.newest?.note == "image_0001.png" && sent.newest?.width == 4)
        #expect(await model.publishForCanvas(GalleryPicture(url: first.appendingPathExtension("sealed"), flow: editor.name, modified: .now), bytes: red) == nil, "a sealed picture is a copy")

        // A run of it finishes: its first picture kept is v2; a preview isn't.
        let second = outputs.appending(path: "image_0002.png")
        try blue.write(to: second)
        let run = RunItem(flowName: editor.name, flow: editor.url, backend: model.queue.backend)
        run.outputs = [
            .init(node: "8", image: "p", file: model.queue.previewsFolder.appending(path: "p.png"), data: red, width: 4, height: 4, kept: false),
            .init(node: "9", image: "s", file: second, data: blue, width: 4, height: 4, kept: true),
        ]
        model.finished(run)
        await model.linking?.value
        #expect(project.asset(sent.id)?.versions.map(\.note) == ["image_0001.png", "image_0002.png"])
        #expect(try await project.pool.data(try #require(project.asset(sent.id)?.newest).blob) == blue)
    }
}
