import Foundation
import Testing
@testable import DiffuseCore

/// A real run on forge through Nexus's gateway, as Photon sends one: only
/// when `PHOTON_LIVE_FORGE` is set, as it needs the gateway and the key
/// (`NEXUS_KEY`, from the environment or the login shell).
///
///   PHOTON_LIVE_FORGE=1 swift test --filter LiveForgeTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTON_LIVE_FORGE"] != nil))
struct LiveForgeTests {
    @Test(.timeLimit(.minutes(3))) func theLighthouseRunsOnForge() async throws {
        let key = try #require(GatewayKey.find(), "no NEXUS_KEY in the environment or the login shell")
        let backend = NexusBackend(settings: GatewaySettings.current(), key: key)
        let health = await backend.health()
        try #require(health.state == .serving, "forge isn't serving: \(health.message)")
        #expect(RunRoute.decide(.automatic, graphJSON: nil, models: [], forge: health.state).local == false, "Automatic goes to forge while it serves")

        let library = try await backend.library()
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: library)
        try #require(editor.problems.isEmpty, "\(editor.problems.map(\.message))")
        let queue = RunQueue(backend: backend)
        let started = Date.now
        queue.run(editor)
        let run = try #require(queue.runs.first)
        while run.phase.isLive { try await Task.sleep(for: .milliseconds(200)) }
        guard case .done(let seconds) = run.phase else {
            Issue.record("the run ended \(run.phase)")
            return
        }
        let file = try #require(run.outputs.first?.file)
        let head = try #require(PictureHead.read(file))
        print("forge made \(file.lastPathComponent), \(head.width) × \(head.height), in \(seconds) s (\(String(format: "%.1f", Date.now.timeIntervalSince(started))) s here)")
        #expect(head.made?.prompt?.contains("lighthouse") == true, "forge writes the graph into the PNG")
    }
}
