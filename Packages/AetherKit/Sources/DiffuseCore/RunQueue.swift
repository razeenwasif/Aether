import Foundation
import Observation

/// One run of a flow, as it happens.
@MainActor
@Observable
public final class RunItem: Identifiable {
    public enum Phase: Equatable, Sendable {
        case sending
        case queued(position: Int)
        case running
        case done(seconds: Double)
        case failed(String)
        case cancelled

        public var isLive: Bool {
            switch self {
            case .sending, .queued, .running: true
            default: false
            }
        }
    }

    public struct Steps: Equatable, Sendable {
        public var step: Int
        public var steps: Int
        public var fraction: Double { steps > 0 ? Double(step) / Double(steps) : 0 }
    }

    public struct Output: Identifiable, Sendable {
        public var id: String { image }
        public var node: String
        public var image: String
        public var file: URL?
        public var data: Data
        public var width: Int
        public var height: Int
    }

    public let id = UUID()
    public let flowName: String
    public let started = Date.now
    public internal(set) var runID: String?
    public internal(set) var phase: Phase = .sending
    public internal(set) var nodeStates: [String: NodeRunState] = [:]
    public internal(set) var steps: [String: Steps] = [:]
    /// The newest preview: the node it came from and a JPEG.
    public internal(set) var preview: (node: String, jpeg: Data)?
    public internal(set) var outputs: [Output] = []

    init(flowName: String) {
        self.flowName = flowName
    }

    /// The node running now, if any.
    public var runningNode: String? { nodeStates.first { $0.value == .running }?.key }
}

/// The runs sent from this window, newest first, and the backend they go to.
@MainActor
@Observable
public final class RunQueue {
    public private(set) var runs: [RunItem] = []
    public private(set) var backend: any ImageBackend
    public private(set) var health: Health = .looking

    public init(backend: any ImageBackend) {
        self.backend = backend
    }

    public var active: RunItem? { runs.first { $0.phase.isLive } }

    public func use(_ backend: any ImageBackend) {
        self.backend = backend
        health = .looking
    }

    /// Look at the backend again; answers its live catalogue when it serves.
    @discardableResult
    public func look() async -> NodeLibrary? {
        health = .looking
        let backend = self.backend
        health = await backend.health()
        guard health.state == .serving, let library = try? await backend.library() else { return nil }
        LibraryCache.keep(library)
        return library
    }

    /// Send `editor`'s flow, follow it to the end, and keep what it makes in
    /// the flow's outputs folder.
    public func run(_ editor: FlowEditor) {
        let item = RunItem(flowName: editor.name)
        runs.insert(item, at: 0)
        let graph: String
        do {
            graph = try editor.graphJSON()
        } catch {
            item.phase = .failed(describe(error))
            return
        }
        let places = outputPlaces(for: editor)
        let backend = self.backend
        Task {
            do {
                let queued = try await backend.run(graphJSON: graph)
                item.runID = queued.run
                item.phase = .queued(position: queued.position)
                // The graph went with this run's seeds; move them for the next.
                editor.apply(editor.seedsAfterRun())
                for try await event in backend.events(run: queued.run) {
                    await handle(event, in: item, backend: backend, places: places)
                }
                if item.phase.isLive { item.phase = .failed("The run's progress stopped before it ended") }
            } catch {
                if item.phase.isLive { item.phase = .failed(describe(error)) }
            }
        }
    }

    public func cancel(_ item: RunItem) {
        guard let run = item.runID, item.phase.isLive else { return }
        let backend = self.backend
        Task { try? await backend.cancel(run: run) }
    }

    private func handle(_ event: RunEvent, in item: RunItem, backend: any ImageBackend, places: [String: OutputPlace]) async {
        switch event {
        case .queued(let position):
            item.phase = .queued(position: position)
        case .started:
            item.phase = .running
        case let .node(id, state):
            item.phase = .running
            item.nodeStates[id] = state
        case let .progress(id, step, steps):
            item.steps[id] = .init(step: step, steps: steps)
        case let .preview(id, _, jpeg):
            if let data = Data(base64Encoded: jpeg) { item.preview = (id, data) }
        case let .image(id, image, _, width, height):
            guard let data = try? await backend.image(image) else { return }
            let place = places[id] ?? OutputPlace(folder: LibraryCache.directory.appending(path: "previews"), prefix: "image")
            try? FileManager.default.createDirectory(at: place.folder, withIntermediateDirectories: true)
            let file = OutputNaming.next(in: place.folder, prefix: place.prefix)
            let kept = (try? data.write(to: file, options: .atomic)) != nil
            item.outputs.append(.init(node: id, image: image, file: kept ? file : nil, data: data, width: width, height: height))
        case let .error(id, _, message):
            item.phase = .failed(id.map { "Node \($0): \(message)" } ?? message)
        case .done(let seconds):
            item.phase = .done(seconds: seconds)
        case .cancelled:
            item.phase = .cancelled
        }
    }

    /// Where each output node's pictures go. A node with a prefix (Save
    /// Image) saves into the flow's outputs folder, which the gallery shows;
    /// one without (Preview Image) into a previews folder that it does not.
    private func outputPlaces(for editor: FlowEditor) -> [String: OutputPlace] {
        let base = editor.url.deletingLastPathComponent()
        let outputs: URL
        if let custom = editor.flow.outputs, !custom.isEmpty {
            outputs = base.appending(path: custom, directoryHint: .isDirectory)
        } else {
            outputs = base.appending(path: "outputs/\(editor.name)", directoryHint: .isDirectory)
        }
        let previews = LibraryCache.directory.appending(path: "previews", directoryHint: .isDirectory)
        var places: [String: OutputPlace] = [:]
        for node in editor.flow.nodes {
            guard let type = editor.library.catalogue.node(node.type), type.isOutput else { continue }
            if let field = type.fields.first(where: { $0.name == "prefix" }) {
                let prefix = node.values["prefix"]?.stringValue ?? field.default?.stringValue ?? "image"
                places[node.id] = OutputPlace(folder: outputs, prefix: prefix)
            } else {
                places[node.id] = OutputPlace(folder: previews, prefix: node.type.lowercased())
            }
        }
        return places
    }
}

/// Where one output node's pictures are written.
struct OutputPlace: Sendable {
    var folder: URL
    var prefix: String
}
