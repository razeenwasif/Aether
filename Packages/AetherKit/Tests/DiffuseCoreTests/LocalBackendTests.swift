import CoreGraphics
import DiffuseBridge
import Foundation
import Testing
@testable import DiffuseCore

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aether-local-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A model folder shaped as Apple's compiled SDXL resources are, with no
/// weights in it: enough for discovery.
private func fakeModel(in folder: URL, named name: String, latent: Int = 128, encoder: Bool = true, answersTo: [String]? = nil) throws -> URL {
    let dir = folder.appending(path: name, directoryHint: .isDirectory)
    var parts = ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc"]
    if encoder { parts.append("VAEEncoder.mlmodelc") }
    for part in parts { try FileManager.default.createDirectory(at: dir.appending(path: part), withIntermediateDirectories: true) }
    for file in ["vocab.json", "merges.txt"] { try Data("{}".utf8).write(to: dir.appending(path: file)) }
    let metadata = #"[{"inputSchema": [{"name": "sample", "shape": "[2, 4, \#(latent), \#(latent)]"}]}]"#
    try Data(metadata.utf8).write(to: dir.appending(path: "Unet.mlmodelc/metadata.json"))
    if let answersTo {
        let named = try JSONSerialization.data(withJSONObject: ["name": name, "answersTo": answersTo])
        try named.write(to: dir.appending(path: "aether-model.json"))
    }
    return dir
}

@MainActor
private func graph(_ template: String? = nil, edit: [FlowOp] = []) throws -> String {
    let editor: FlowEditor
    if let template {
        editor = try FlowEditor.create(at: scratch().appending(path: "t.flow.json"), template: template, library: Fixture.library())
    } else {
        editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
    }
    if !edit.isEmpty { #expect(editor.apply(edit) != nil, "\(editor.refusal ?? "")") }
    return try editor.graphJSON()
}

/// Makes flat pictures the plan's size, reporting each step.
private struct FlatPictures: LocalPipeline {
    var pause: Duration = .zero

    func generate(_ plan: LocalPlan, model: LocalModel, startingImage: CGImage?,
                  progress: @escaping @Sendable (Int, Int) -> Bool) throws -> [CGImage] {
        for step in 1...plan.steps {
            if pause > .zero { Thread.sleep(forTimeInterval: Double(pause.components.attoseconds) / 1e18) }
            guard progress(step, plan.steps) else { throw LocalBackend.Failure.stopped }
        }
        let context = CGContext(data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: startingImage == nil ? 0.5 : 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        return Array(repeating: context.makeImage()!, count: plan.count)
    }
}

@MainActor
struct LocalPlanTests {
    @Test func aTextToImageFlowPlansAsTheSamplerSays() throws {
        let plan = try LocalPlan.make(graphJSON: graph()).get()
        #expect(plan.checkpoint.hasPrefix("sd_xl_base"))
        #expect(plan.prompt.contains("lighthouse") && !plan.negative.isEmpty)
        #expect(plan.width == 1024 && plan.height == 1024 && plan.count == 1)
        #expect(plan.steps == 30 && plan.cfg == 6.5)
        #expect(plan.scheduler == .dpmSolverMultistep(karras: true))
        #expect(plan.startingImage == nil && plan.strength == 1)
        #expect(plan.sampler == "5" && plan.outputs == ["7"])
        #expect(plan.notes.isEmpty, "\(plan.notes)")
    }

    @Test func anImageToImageFlowStartsFromItsPicture() throws {
        let editor = try FlowEditor.create(at: scratch().appending(path: "i.flow.json"), template: "imageToImage", library: Fixture.library())
        editor.usePicture("local-upload-1.png")
        let plan = try LocalPlan.make(graphJSON: editor.graphJSON()).get()
        #expect(plan.startingImage == "local-upload-1.png")
        #expect(plan.strength < 1 && plan.strength > 0)
        #expect(plan.notes.contains { $0.contains("scaled") })
    }

    @Test func whatThisMacCantDoIsRefusedInWords() throws {
        let inpaint = try FlowEditor.create(at: scratch().appending(path: "p.flow.json"), template: "inpaint", library: Fixture.library())
        inpaint.usePicture("local-upload-1.png")
        let masked = try #require(LocalPlan.make(graphJSON: inpaint.graphJSON()).failure)
        #expect(masked.message.contains("masks"))

        let hires = try #require(LocalPlan.make(graphJSON: graph("hiresFix")).failure)
        #expect(hires.message.contains("upscaling") && hires.message.contains("2 samplers"))

        let wide = try #require(LocalPlan.make(graphJSON: graph(edit: [.set(id: "4", name: "width", value: .int(1216)), .set(id: "4", name: "height", value: .int(832))])).failure)
        #expect(wide.message.contains("1024 × 1024 only") && wide.message.contains("1216 × 832"))
    }

    @Test func whereThisMacDiffersIsSaid() throws {
        let plan = try LocalPlan.make(graphJSON: graph(edit: [
            .set(id: "5", name: "sampler", value: .string("euler_a")),
            .set(id: "5", name: "scheduler", value: .string("normal")),
            .set(id: "5", name: "seed", value: .int(Int64(UInt32.max) + 7)),
        ])).get()
        #expect(plan.scheduler == .dpmSolverMultistep(karras: false))
        #expect(plan.notes.contains { $0.contains("euler_a") })
        #expect(plan.seed == 6 && plan.notes.contains { $0.contains("2³²") })
    }
}

@MainActor
struct LocalBackendTests {
    @Test func modelsAreFoundWithTheirSizeAndNames() throws {
        let folder = try scratch()
        _ = try fakeModel(in: folder, named: "SDXL base (4.5-bit)", answersTo: ["sd_xl_base_1.0.safetensors"])
        _ = try fakeModel(in: folder, named: "small", latent: 64, encoder: false)
        try FileManager.default.createDirectory(at: folder.appending(path: "half-downloaded"), withIntermediateDirectories: true)

        let models = LocalModels.installed(in: folder)
        #expect(models.map(\.name) == ["SDXL base (4.5-bit)", "small"])
        #expect(models[0].side == 1024 && models[0].takesPictures && models[0].answers("sd_xl_base_1.0.safetensors"))
        #expect(models[1].side == 512 && !models[1].takesPictures && models[1].answersTo == ["small"])
    }

    @Test func aRunOnThisMacMakesAPictureWithItsGraphIn() async throws {
        let folder = try scratch()
        _ = try fakeModel(in: folder, named: "SDXL base", answersTo: ["sd_xl_base_1.0.safetensors"])
        let backend = LocalBackend(pipeline: FlatPictures(), modelsFolder: folder)
        #expect(await backend.health().state == .serving)

        let sent = try graph(edit: [.set(id: "5", name: "steps", value: .int(4))])
        let queued = try await backend.run(graphJSON: sent)
        var events: [RunEvent] = []
        for try await event in backend.events(run: queued.run) { events.append(event) }
        #expect(events.first == .started && events.last.map { if case .done = $0 { true } else { false } } == true)
        #expect(events.filter { if case .progress = $0 { true } else { false } }.count == 4)
        guard case let .image(node, image, _, width, height) = try #require(events.first(where: { if case .image = $0 { true } else { false } })) else { return }
        #expect(node == "7" && width == 1024 && height == 1024)

        let file = try scratch().appending(path: "made.png")
        try await backend.image(image).write(to: file)
        let head = try #require(PictureHead.read(file))
        #expect(head.width == 1024 && head.made?.prompt?.contains("lighthouse") == true, "the graph is in the PNG, as forge writes it")
    }

    @Test func aRunWithNoModelForItsCheckpointIsRefused() async throws {
        let empty = LocalBackend(pipeline: FlatPictures(), modelsFolder: try scratch())
        #expect(await empty.health().state == .offline)
        await #expect(throws: LocalBackend.Failure.self) { try await empty.run(graphJSON: try graph()) }

        let folder = try scratch()
        _ = try fakeModel(in: folder, named: "another model")
        let other = LocalBackend(pipeline: FlatPictures(), modelsFolder: folder)
        do {
            _ = try await other.run(graphJSON: try graph())
            Issue.record("ran with no model for sd_xl_base")
        } catch let failure as LocalBackend.Failure {
            #expect(failure.localizedDescription.contains("sd_xl_base"))
        }
    }

    @Test func aRunCanBeStoppedBetweenSteps() async throws {
        let folder = try scratch()
        _ = try fakeModel(in: folder, named: "SDXL base", answersTo: ["sd_xl_base_1.0.safetensors"])
        let backend = LocalBackend(pipeline: FlatPictures(pause: .milliseconds(20)), modelsFolder: folder)
        let queued = try await backend.run(graphJSON: graph(edit: [.set(id: "5", name: "steps", value: .int(60))]))
        var events: [RunEvent] = []
        for try await event in backend.events(run: queued.run) {
            events.append(event)
            if case .progress(_, 3, _) = event { try await backend.cancel(run: queued.run) }
        }
        #expect(events.last == .cancelled)
        #expect(!events.contains { if case .image = $0 { true } else { false } })
    }

    @Test func theRunQueueKeepsALocalRunsPictureInTheFlowsOutputs() async throws {
        let folder = try scratch()
        _ = try fakeModel(in: folder, named: "SDXL base", answersTo: ["sd_xl_base_1.0.safetensors"])
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        #expect(editor.apply([.set(id: "5", name: "steps", value: .int(3))]) != nil)
        let queue = RunQueue(backend: LocalBackend(pipeline: FlatPictures(), modelsFolder: folder))
        queue.run(editor)
        let run = try #require(queue.runs.first)
        for _ in 0..<300 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        guard case .done = run.phase else { Issue.record("\(run.phase)"); return }
        let file = try #require(run.outputs.first?.file)
        #expect(file.deletingLastPathComponent().path.hasSuffix("outputs/lighthouse"))
        #expect(PictureHead.read(file)?.made?.steps == 3)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { f } else { nil } }
}
