import CoreGraphics
import DiffuseBridge
import Foundation
import Observation

/// A flow open for editing. Every change goes to the core as a batch of ops,
/// applied whole or refused whole; the flow shown is always what the core
/// holds, read back after each change.
@MainActor
@Observable
public final class FlowEditor {
    public private(set) var flow: Flow
    public private(set) var problems: [Problem] = []
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isDirty = false
    public private(set) var library: NodeLibrary
    /// Why the last edit was refused, in the core's words.
    public private(set) var refusal: String?
    public var selection: Set<String> = []
    /// The plain file's place; a sealed flow is kept beside it, `.sealed`.
    public private(set) var url: URL
    /// Whether it is kept sealed with Proton's key, and so are its outputs.
    public private(set) var isSealed: Bool
    /// The key it is sealed with; `nil` for a plain flow.
    @ObservationIgnored public private(set) var sealKey: SealKey?

    /// Told of each new step in its history, by name, with the nodes it
    /// added: so the project can keep every document's steps in one history.
    @ObservationIgnored public var onStep: ((String, [String]) -> Void)?

    @ObservationIgnored private var document: FlowDocument
    @ObservationIgnored private let decoder = JSONDecoder()
    @ObservationIgnored private let encoder = JSONEncoder()

    private init(document: FlowDocument, url: URL, library: NodeLibrary, key: SealKey? = nil) throws {
        self.document = document
        self.url = url
        self.library = library
        isSealed = document.isSealed()
        sealKey = document.isSealed() ? key : nil
        flow = try decoder.decode(Flow.self, from: Data(document.flowJson().utf8))
        refresh()
    }

    /// The flow at `url`, the plain file's place: its sealed file opened
    /// with `key` when there is one, else the plain file. Saved the way it
    /// was found.
    public static func open(_ url: URL, library: NodeLibrary, key: SealKey? = nil) throws -> FlowEditor {
        let url = SealedFiles.plain(url)
        return try FlowEditor(document: FlowDocument.open(path: url.path, key: key), url: url, library: library, key: key)
    }

    /// A new flow at `url`, not written until saved, started from a template
    /// when one is named.
    public static func create(at url: URL, template: String?, library: NodeLibrary) throws -> FlowEditor {
        let document = try FlowDocument.create(path: url.path, flowJson: #"{"format": 1}"#)
        if let template, let ops = templateOps(name: template) {
            _ = try document.apply(opsJson: ops, catalogue: library.core)
        }
        return try FlowEditor(document: document, url: url, library: library)
    }

    /// A new flow at `url` holding `flowJSON`, not written until saved.
    public static func create(at url: URL, flowJSON: String, library: NodeLibrary) throws -> FlowEditor {
        try FlowEditor(document: FlowDocument.create(path: url.path, flowJson: flowJSON), url: url, library: library)
    }

    /// A new flow from the graph a picture holds, laid out by the core, and
    /// sealed with `key` when given: a sealed picture's graph stays sealed.
    public static func create(at url: URL, fromGraph graphJSON: String, library: NodeLibrary, sealedWith key: SealKey? = nil) throws -> FlowEditor {
        let document = try FlowDocument.create(path: url.path, flowJson: flowFromGraph(graphJson: graphJSON, catalogue: library.core))
        if let key { document.sealWith(key: key) }
        return try FlowEditor(document: document, url: url, library: library, key: key)
    }

    /// The flow's name: its file's, without `.flow.json`.
    public var name: String {
        var name = url.lastPathComponent
        for suffix in [".json", ".flow"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name
    }

    // MARK: Editing

    /// Apply `ops` as one undo step. Answers the ids of nodes added, or `nil`
    /// when the core refused the batch (and says why in `refusal`).
    @discardableResult
    public func apply(_ ops: [FlowOp]) -> [String]? {
        guard !ops.isEmpty else { return [] }
        do {
            let json = String(decoding: try encoder.encode(ops), as: UTF8.self)
            let applied = try decoder.decode(Applied.self, from: Data(document.apply(opsJson: json, catalogue: library.core).utf8))
            refusal = nil
            if applied.changed {
                refresh()
                onStep?(FlowOp.label(of: ops), applied.added)
            }
            return applied.added
        } catch {
            refusal = describe(error)
            return nil
        }
    }

    /// Take back the newest step; answers whether there was one.
    @discardableResult
    public func undo() -> Bool {
        guard document.undo() else { return false }
        refresh()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard document.redo() else { return false }
        refresh()
        return true
    }

    public func clearRefusal() { refusal = nil }

    /// Write the flow, whole or not at all.
    public func save() throws {
        try document.save()
        refresh()
    }

    /// Save to a new place: the flow from now on lives there, sealed if it
    /// was.
    public func save(as newURL: URL) throws {
        let newURL = SealedFiles.plain(newURL)
        let next = try FlowDocument.create(path: newURL.path, flowJson: document.flowJson())
        if isSealed { next.sealWith(key: sealKey) }
        try next.save()
        document = next
        url = newURL
        refresh()
    }

    /// Use another catalogue — the server's, once it answers.
    public func use(_ library: NodeLibrary) {
        self.library = library
        refresh()
    }

    // MARK: Pictures

    /// The field a node takes its picture in, if it takes one.
    public func pictureField(of node: FlowNode) -> String? {
        library.catalogue.node(node.type)?.fields.first { $0.fieldKind == .upload }?.name
    }

    /// Give a Load Image the picture `name`: the node and field given, else
    /// the Load Image selected, else the first; with none in the flow, add
    /// one with it at `at`, or under the rest. One undo step. Answers the
    /// node's id, or `nil` when the core refused (and says why in `refusal`).
    @discardableResult
    public func usePicture(_ name: String, node target: String? = nil, field: String? = nil, at: CGPoint? = nil) -> String? {
        if let (node, field) = pictureTarget(target, field: field) {
            guard apply([.set(id: node, name: field, value: .string(name))]) != nil else { return nil }
            selection = [node]
            return node
        }
        guard library.catalogue.node("LoadImage") != nil else {
            refusal = "The server has no Load Image node to take the picture."
            return nil
        }
        let lowest = flow.nodes.map(\.position.y).max().map { $0 + 300 } ?? 16
        let place = at ?? CGPoint(x: 16, y: max(16, lowest))
        guard let added = apply([.add(type: "LoadImage", at: place, values: ["image": .string(name)])]) else { return nil }
        selection = Set(added)
        return added.first
    }

    /// The node and field `usePicture` gives a picture to: the node given,
    /// else the Load Image selected, else the first; `nil` when it would add
    /// a Load Image.
    public func pictureTarget(_ target: String?, field: String?) -> (node: String, field: String)? {
        let loads = flow.nodes.filter { pictureField(of: $0) != nil }
        guard let node = target.flatMap({ flow.node($0) }) ?? loads.first(where: { selection.contains($0.id) }) ?? loads.first,
              let field = field ?? pictureField(of: node) else { return nil }
        return (node.id, field)
    }

    /// A picture a node names that isn't in the flow's folder, sealed or
    /// plain: said on its node, as Proton says it.
    private func missingPictures() -> [Problem] {
        flow.nodes.flatMap { node -> [Problem] in
            guard !node.isBypassed, let type = library.catalogue.node(node.type) else { return [] }
            return type.fields.compactMap { field in
                guard field.fieldKind == .upload, let name = node.values[field.name]?.stringValue, !name.isEmpty,
                      !SealedFiles.exists(FlowInputs.file(name, flow: url))
                else { return nil }
                return Problem(node: node.id, input: field.name, message: "\(name) isn’t in the flow’s folder: choose the picture again")
            }
        }
    }

    // MARK: Running

    /// The graph a run sends, or the problems that stop it.
    public func graphJSON() throws -> String {
        try document.graph(catalogue: library.core, modelsJson: library.modelsJSON)
    }

    /// The graph a run to `node` sends — only what it needs, the other
    /// outputs left out, and a Preview Image after it when it isn't an
    /// output — with the node in that graph whose picture is `node`'s.
    public func graphJSON(upTo node: String) throws -> GraphTo {
        try document.graphTo(node: node, catalogue: library.core, modelsJson: library.modelsJSON)
    }

    /// What each node's seed does after a run: a batch that moves the seeds
    /// of nodes set to increment or random — of those in `ids`, the nodes a
    /// run sent, when given — applied once a run is queued.
    public func seedsAfterRun(in ids: Set<String>? = nil) -> [FlowOp] {
        flow.nodes.compactMap { node in
            guard ids?.contains(node.id) ?? true,
                  let mode = node.seed, mode != .fixed,
                  let kind = library.catalogue.node(node.type),
                  let field = kind.fields.first(where: { $0.fieldKind == .seed })
            else { return nil }
            let now = node.values[field.name]?.intValue ?? 0
            let max = Int64(1) << 53 - 1
            let next: Int64 = mode == .increment ? (now >= max ? 0 : now + 1) : Int64.random(in: 0...max)
            return .set(id: node.id, name: field.name, value: .int(next))
        }
    }

    // MARK: Reading back

    private func refresh() {
        if let fresh = try? decoder.decode(Flow.self, from: Data(document.flowJson().utf8)) {
            flow = fresh
        }
        let ids = Set(flow.nodes.map(\.id))
        selection.formIntersection(ids)
        problems = (try? decoder.decode([Problem].self, from: Data(document.problems(catalogue: library.core, modelsJson: library.modelsJSON).utf8))) ?? []
        problems += missingPictures()
        canUndo = document.canUndo()
        canRedo = document.canRedo()
        isDirty = document.isDirty()
    }

    /// The problems at one node.
    public func problems(at node: String) -> [Problem] { problems.filter { $0.node == node } }
}

/// The core's words for an error, without the type's decoration.
public func describe(_ error: Error) -> String {
    if let e = error as? DiffuseError {
        switch e {
        case .Failed(let message), .Gateway(_, let message): return message
        }
    }
    return error.localizedDescription
}
