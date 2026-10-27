import DiffuseBridge
import Foundation
import Testing
@testable import DiffuseCore

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aether-to-here-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
struct RunToHereTests {
    @Test func aRunToASamplerShowsItsPictureOnTheSampler() async throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let to = try editor.graphJSON(upTo: "5")
        #expect(to.shows != "5" && editor.flow.node(to.shows) == nil, "the Preview Image is the run's, not the flow's")

        let picture = PNGFixture.head(width: 64, height: 64, flow: nil)
        let backend = PictureAt(node: to.shows, picture: picture)
        let queue = RunQueue(backend: backend)
        queue.previewsFolder = try scratch()
        queue.run(editor, upTo: "5")
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(run.phase == .done(seconds: 0.1) && run.target == "5")

        let output = try #require(run.outputs.first)
        #expect(output.node == "5")
        #expect(output.file?.deletingLastPathComponent().standardizedFileURL == queue.previewsFolder.standardizedFileURL)
        let sent = try #require(await backend.graphs.first)
        #expect(!sent.contains("SaveImage") && sent.contains("PreviewImage"))
    }

    @Test func onlyTheSeedsARunSentMove() async throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        // A second sampler, wired to nothing: not in any run's graph.
        let loose = try #require(editor.apply([.add(type: "KSampler", at: CGPoint(x: 900, y: 600))])?.first)
        #expect(editor.apply([.seed(id: "5", mode: .increment), .seed(id: loose, mode: .increment)]) != nil)
        let looseSeed = editor.flow.node(loose)?.values["seed"]
        let seed = try #require(editor.flow.node("5")?.values["seed"]?.intValue)

        let queue = RunQueue(backend: PictureAt(node: "none", picture: Data()))
        queue.previewsFolder = try scratch()
        queue.run(editor, upTo: "6")
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.flow.node("5")?.values["seed"]?.intValue == seed + 1)
        #expect(editor.flow.node(loose)?.values["seed"] == looseSeed)
    }

    @Test func aRunToANodeWithNoPictureIsRefused() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let queue = RunQueue(backend: PictureAt(node: "none", picture: Data()))
        queue.run(editor, upTo: "2")
        guard case .failed(let why) = queue.runs.first?.phase else { Issue.record("not refused"); return }
        #expect(why.contains("neither an image nor a latent"))
    }
}

/// A backend whose runs make one picture at `node`, keeping the graphs sent.
private actor PictureAt: ImageBackend {
    let node: String
    let picture: Data
    private(set) var graphs: [String] = []

    init(node: String, picture: Data) {
        self.node = node
        self.picture = picture
    }

    nonisolated var displayName: String { "Picture at" }
    func health() async -> Health { .looking }
    func library() async throws -> NodeLibrary { try Fixture.library() }
    func upload(_ picture: Data) async throws -> String { "upload1" }
    func run(graphJSON: String) async throws -> Queued {
        graphs.append(graphJSON)
        return Queued(run: "run1", position: 0)
    }
    nonisolated func events(run: String) -> AsyncThrowingStream<RunEvent, Error> {
        let node = self.node
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.image(id: node, image: "run1_\(node)", index: 0, width: 64, height: 64))
            continuation.yield(.done(seconds: 0.1))
            continuation.finish()
        }
    }
    func image(_ id: String) async throws -> Data { picture }
    func cancel(run: String) async throws {}
}
