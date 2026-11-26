import PhotonGraph
import Foundation
import Testing
@testable import PhotonShell
@testable import DiffuseCore

/// Quitting while a flow runs: asked about, and the run stopped.
@MainActor
struct QuitDuringARunTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "photon-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let defaults = UserDefaults(suiteName: "photon-tests-\(UUID().uuidString)")!

    /// A model with its untitled flow sent to `backend`, queued there.
    private func running(on backend: some ImageBackend) async throws -> (AppModel, FlowEditor) {
        let model = AppModel(project: try ProjectGraph.create(base.appending(path: "One.photon")), defaults: defaults, connecting: false)
        let flow = try #require(model.diffuse.editor)
        model.diffuse.queue.run(flow, on: backend)
        for _ in 0..<200 where model.diffuse.queue.live.first?.runID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.diffuse.queue.live.first?.runID == "run1")
        return (model, flow)
    }

    @Test func quittingDuringARunAsksFirstAndStopsIt() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let backend = Endless()
        let (model, flow) = try await running(on: backend)
        var asked: [[String]] = []
        var quit = false
        model.askAboutRuns = { flows in
            asked.append(flows)
            return quit
        }
        var unsavedAsked = 0
        model.askAboutUnsaved = { _, _ in
            unsavedAsked += 1
            return .drop
        }

        // Cancel stays, asks nothing more, and leaves the run going.
        #expect(!model.shouldQuit())
        #expect(asked == [[flow.name]] && unsavedAsked == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await backend.cancelled.isEmpty, "nothing was stopped")
        #expect(model.diffuse.queue.live.count == 1)

        // Quit goes on to what isn't saved, then stops the run on its backend.
        quit = true
        #expect(flow.apply([.set(id: "5", name: "steps", value: .int(3))]) != nil)
        #expect(model.shouldQuit())
        #expect(unsavedAsked == 1, "then what isn't saved")
        await model.stopRuns()
        #expect(await backend.cancelled == ["run1"])
    }

    @Test func nothingRunningAsksNothingAboutRuns() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let model = AppModel(project: try ProjectGraph.create(base.appending(path: "One.photon")), defaults: defaults, connecting: false)
        var asked = false
        model.askAboutRuns = { _ in
            asked = true
            return false
        }
        #expect(model.shouldQuit() && !asked)
    }

    @Test func aBackendThatDoesntAnswerDoesntHoldTheQuit() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (model, _) = try await running(on: Endless(answers: false))
        let start = ContinuousClock.now
        await model.stopRuns(waiting: 0.2)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

/// A backend whose runs never end until they're cancelled; with `answers`
/// false, a cancel that's never answered, as forge away would be.
private actor Endless: ImageBackend {
    let answers: Bool
    private(set) var cancelled: [String] = []
    private let stream: AsyncThrowingStream<RunEvent, Error>
    private let continuation: AsyncThrowingStream<RunEvent, Error>.Continuation

    init(answers: Bool = true) {
        self.answers = answers
        (stream, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(.started)
    }

    nonisolated var displayName: String { "Endless" }
    func health() async -> Health { .looking }
    func library() async throws -> NodeLibrary { throw CancellationError() }
    func upload(_ picture: Data) async throws -> String { "upload1" }
    func run(graphJSON: String) async throws -> Queued { Queued(run: "run1", position: 0) }
    nonisolated func events(run: String) -> AsyncThrowingStream<RunEvent, Error> { stream }
    func image(_ id: String) async throws -> Data { Data() }
    func cancel(run: String) async throws {
        guard answers else {
            try await Task.sleep(for: .seconds(60))
            return
        }
        cancelled.append(run)
        continuation.finish()
    }
}
