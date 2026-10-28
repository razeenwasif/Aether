import DiffuseBridge
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
        /// Written where the Gallery shows it, as a Save Image's is; not a
        /// preview's.
        public var kept: Bool = false
    }

    public let id = UUID()
    public let flowName: String
    /// The flow's file, when the run was sent: what publishes its pictures.
    public let flow: URL?
    /// The node a run to here runs to; `nil` for a run of the whole flow.
    public let target: String?
    /// Where it runs: forge through Nexus, or this Mac.
    public let backend: any ImageBackend
    public let started = Date.now
    public internal(set) var runID: String?
    public internal(set) var phase: Phase = .sending
    public internal(set) var nodeStates: [String: NodeRunState] = [:]
    public internal(set) var steps: [String: Steps] = [:]
    /// The newest preview: the node it came from and a JPEG.
    public internal(set) var preview: (node: String, jpeg: Data)?
    public internal(set) var outputs: [Output] = []
    /// Nodes added to the graph sent whose pictures are a flow node's: a
    /// run to here's Preview Image, shown on the node run to.
    var shownAs: [String: String] = [:]

    init(flowName: String, flow: URL? = nil, target: String? = nil, backend: any ImageBackend) {
        self.flowName = flowName
        self.flow = flow
        self.target = target
        self.backend = backend
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
    /// Where pictures that aren't kept go: Preview Image's, and a run to
    /// here's. Not shown in the Gallery.
    public var previewsFolder = LibraryCache.directory.appending(path: "previews", directoryHint: .isDirectory)
    /// Told when a run finishes, its pictures written.
    @ObservationIgnored public var onFinished: ((RunItem) -> Void)?

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

    /// Look at the backend again without saying "looking" in between, as
    /// the regular check does: the health changes only when the answer
    /// comes. Answers the live catalogue when the backend has just come
    /// back to serving.
    @discardableResult
    public func check() async -> NodeLibrary? {
        let backend = self.backend
        let was = health.state
        let now = await backend.health()
        health = now
        guard now.state == .serving, was != .serving, let library = try? await backend.library() else { return nil }
        LibraryCache.keep(library)
        return library
    }

    /// Send `editor`'s flow, follow it to the end, and keep what it makes in
    /// the flow's outputs folder. Each picture a Load Image names is sent
    /// first, with its painted mask in its alpha, and its upload named in
    /// the graph; `key` reads sealed pictures in a plain flow. With `node`,
    /// a run to here: only what that node needs, its picture shown on it.
    /// With `place`, on that backend instead of the queue's (this Mac's).
    public func run(_ editor: FlowEditor, key: SealKey? = nil, upTo node: String? = nil, on place: (any ImageBackend)? = nil) {
        let backend = place ?? self.backend
        let item = RunItem(flowName: editor.name, flow: editor.url, target: node, backend: backend)
        runs.insert(item, at: 0)
        let graph: String
        do {
            if let node {
                let to = try editor.graphJSON(upTo: node)
                graph = to.graph
                if to.shows != node { item.shownAs[to.shows] = node }
            } else {
                graph = try editor.graphJSON()
            }
        } catch {
            item.phase = .failed(describe(error))
            return
        }
        let sent = Self.nodes(of: graph)
        let places = outputPlaces(for: editor)
        // A node the graph gained (a run to here's Preview Image) keeps its
        // picture with the previews, sealed if the flow is.
        let fallback = OutputPlace(folder: previewsFolder, prefix: "preview", key: editor.isSealed ? editor.sealKey : nil)
        let pictures: [GraphPicture]
        do {
            pictures = try JSONDecoder().decode([GraphPicture].self, from: Data(graphPictures(graphJson: graph, catalogue: editor.library.core).utf8))
        } catch {
            item.phase = .failed(describe(error))
            return
        }
        let flow = editor.url
        let readKey = editor.sealKey ?? key
        Task {
            do {
                let sending = try await Self.uploading(pictures, of: graph, flow: flow, key: readKey, to: backend)
                let queued = try await backend.run(graphJSON: sending)
                item.runID = queued.run
                item.phase = .queued(position: queued.position)
                // The graph went with this run's seeds; move them for the next.
                editor.apply(editor.seedsAfterRun(in: sent))
                for try await event in backend.events(run: queued.run) {
                    await handle(event, in: item, backend: backend, places: places, fallback: fallback)
                }
                if item.phase.isLive { item.phase = .failed("The run's progress stopped before it ended") }
            } catch {
                if item.phase.isLive { item.phase = .failed(describe(error)) }
            }
        }
    }

    /// The graph with each picture uploaded and named by its upload.
    private static func uploading(_ pictures: [GraphPicture], of graph: String, flow: URL, key: SealKey?, to backend: any ImageBackend) async throws -> String {
        guard !pictures.isEmpty else { return graph }
        var named: [[String: String]] = []
        for picture in pictures {
            let file = FlowInputs.file(picture.value, flow: flow)
            guard SealedFiles.exists(file) else { throw PictureMissing(name: picture.value) }
            let mask = FlowInputs.mask(node: picture.node, flow: flow)
            let maskPath = SealedFiles.exists(mask) ? mask.path : nil
            let bytes = try await offMain { try uploadBytes(file: file.path, mask: maskPath, key: key) }
            let id = try await backend.upload(bytes)
            named.append(["node": picture.node, "field": picture.field, "id": id])
        }
        let uploads = String(decoding: try JSONEncoder().encode(named), as: UTF8.self)
        return try graphWithUploads(graphJson: graph, uploadsJson: uploads)
    }

    public func cancel(_ item: RunItem) {
        guard let run = item.runID, item.phase.isLive else { return }
        let backend = item.backend
        Task { try? await backend.cancel(run: run) }
    }

    /// The ids of the nodes a graph sends.
    private static func nodes(of graph: String) -> Set<String> {
        struct Sent: Decodable {
            struct Node: Decodable { var id: String }
            var nodes: [Node]
        }
        return Set((try? JSONDecoder().decode(Sent.self, from: Data(graph.utf8)))?.nodes.map(\.id) ?? [])
    }

    private func handle(_ event: RunEvent, in item: RunItem, backend: any ImageBackend, places: [String: OutputPlace], fallback: OutputPlace) async {
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
            let place = places[id] ?? fallback
            let file = OutputNaming.next(in: place.folder, prefix: place.prefix)
            // A sealed flow's pictures are sealed too, as Proton keeps them.
            let kept = (try? writeFile(path: file.path, bytes: data, key: place.key)).map { URL(fileURLWithPath: $0) }
            item.outputs.append(.init(node: item.shownAs[id] ?? id, image: image, file: kept, data: data, width: width, height: height, kept: place.folder != previewsFolder))
        case let .error(id, _, message):
            item.phase = .failed(id.map { "Node \($0): \(message)" } ?? message)
        case .done(let seconds):
            item.phase = .done(seconds: seconds)
            onFinished?(item)
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
        let previews = previewsFolder
        let key = editor.isSealed ? editor.sealKey : nil
        var places: [String: OutputPlace] = [:]
        for node in editor.flow.nodes {
            guard let type = editor.library.catalogue.node(node.type), type.isOutput else { continue }
            if let field = type.fields.first(where: { $0.name == "prefix" }) {
                let prefix = node.values["prefix"]?.stringValue ?? field.default?.stringValue ?? "image"
                places[node.id] = OutputPlace(folder: outputs, prefix: prefix, key: key)
            } else {
                places[node.id] = OutputPlace(folder: previews, prefix: node.type.lowercased(), key: key)
            }
        }
        return places
    }
}

/// A picture a graph sends: the node and field that name it, and its name.
struct GraphPicture: Decodable, Sendable {
    var node: String
    var field: String
    var value: String
}

struct PictureMissing: LocalizedError {
    var name: String
    var errorDescription: String? { "\(name) isn’t in the flow’s folder: choose the picture again" }
}

/// Where one output node's pictures are written, and the key they are
/// sealed with, if any.
struct OutputPlace: Sendable {
    var folder: URL
    var prefix: String
    var key: SealKey?
}
