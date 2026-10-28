import Foundation
import Observation
import os

/// The six workspaces, in the rail's order: each is a view of the graph, and
/// a transaction's origin.
public enum Workspace: String, CaseIterable, Identifiable, Sendable, Codable {
    case design, model, game, canvas, diffuse, video

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// What the navigator toggle is called here: what the navigator holds.
    public var navigatorLabel: String {
        switch self {
        case .design: "Layers"
        case .model: "Outliner"
        case .game: "Entities"
        case .canvas: "Canvases"
        case .diffuse: "Nodes"
        case .video: "Media"
        }
    }

    /// The milestone that builds it (RESEARCH_PLAN.md §8).
    public var milestone: String {
        switch self {
        case .canvas, .model: "M2"
        case .diffuse: "M3"
        case .game: "M4"
        case .design, .video: "M5"
        }
    }

    public var isBuilt: Bool { self == .diffuse || self == .canvas }
}

public struct NodeID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public var description: String { raw.uuidString }
    public static func < (a: NodeID, b: NodeID) -> Bool { a.raw.uuidString < b.raw.uuidString }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let raw = UUID(uuidString: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(text) isn’t an id")) }
        self.raw = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw.uuidString)
    }
}

/// An asset is a node: its id is the node's.
public struct AssetID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let node: NodeID

    public init(_ node: NodeID = NodeID()) {
        self.node = node
    }

    public var description: String { node.description }

    public init(from decoder: Decoder) throws {
        node = try NodeID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }
}

/// A property's value, kept as plain JSON so `project.json` reads as Proton's
/// formats do.
public enum PropertyValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([PropertyValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int? {
        switch self {
        case .int(let n): n
        case .double(let d) where d == d.rounded(): Int(d)
        default: nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Int.self) { self = .int(n) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .list(try c.decode([PropertyValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let n): try c.encode(n)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .list(let l): try c.encode(l)
        }
    }
}

/// One version of an asset: its bytes, kept once in the project's `blobs/`
/// under their SHA-256, and what it was made from.
public struct AssetVersion: Sendable, Hashable, Codable {
    public var number: Int
    /// The bytes' SHA-256, in hex: the file `blobs/<blob>.png`.
    public var blob: String
    public var width: Int
    public var height: Int
    public var made: Date
    /// What it was made from, for people: "key art_0007.png", "saved".
    public var note: String?

    public init(number: Int, blob: String, width: Int, height: Int, made: Date = Date(), note: String? = nil) {
        self.number = number
        self.blob = blob
        self.width = width
        self.height = height
        // To the second, as project.json keeps it.
        self.made = Date(timeIntervalSince1970: made.timeIntervalSince1970.rounded(.down))
        self.note = note
    }
}

public enum NodeKind: String, Sendable, Codable {
    /// Something a workspace makes that others use: a flow's newest
    /// picture, a canvas as saved.
    case asset
    /// A use of an asset: a canvas layer, a Load Image's picture.
    case link
}

/// A node of the project graph: what it is, its properties, and an asset's
/// versions, oldest first.
public struct Node: Sendable, Hashable, Identifiable, Codable {
    public let id: NodeID
    public var kind: NodeKind
    public var properties: [String: PropertyValue]
    public var versions: [AssetVersion]

    public init(id: NodeID = NodeID(), kind: NodeKind, properties: [String: PropertyValue], versions: [AssetVersion] = []) {
        self.id = id
        self.kind = kind
        self.properties = properties
        self.versions = versions
    }

    public subscript(_ property: String) -> PropertyValue? {
        get { properties[property] }
        set { properties[property] = newValue }
    }

    enum CodingKeys: String, CodingKey { case id, kind, properties, versions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NodeID.self, forKey: .id)
        kind = try c.decode(NodeKind.self, forKey: .kind)
        properties = try c.decodeIfPresent([String: PropertyValue].self, forKey: .properties) ?? [:]
        versions = try c.decodeIfPresent([AssetVersion].self, forKey: .versions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(properties, forKey: .properties)
        if !versions.isEmpty { try c.encode(versions, forKey: .versions) }
    }
}

/// One change to the graph. Every op has an inverse, worked out as it is
/// applied (RESEARCH_PLAN.md §6.4, rule 3).
public enum Op: Sendable, Hashable, Codable {
    case insert(Node)
    case remove(NodeID)
    /// A property set, or taken away with `nil`.
    case set(NodeID, property: String, value: PropertyValue?)
    /// A version onto the end of an asset's: the next number.
    case publish(AssetID, AssetVersion)
    /// An asset's newest version taken off: publish's inverse.
    case retract(AssetID, version: Int)

    enum CodingKeys: String, CodingKey { case op, node, property, value, asset, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "insert": self = .insert(try c.decode(Node.self, forKey: .node))
        case "remove": self = .remove(try c.decode(NodeID.self, forKey: .node))
        case "set": self = .set(try c.decode(NodeID.self, forKey: .node), property: try c.decode(String.self, forKey: .property), value: try c.decodeIfPresent(PropertyValue.self, forKey: .value))
        case "publish": self = .publish(try c.decode(AssetID.self, forKey: .asset), try c.decode(AssetVersion.self, forKey: .version))
        case "retract": self = .retract(try c.decode(AssetID.self, forKey: .asset), version: try c.decode(Int.self, forKey: .version))
        case let other: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "\(other) isn’t an op")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insert(let node):
            try c.encode("insert", forKey: .op)
            try c.encode(node, forKey: .node)
        case .remove(let id):
            try c.encode("remove", forKey: .op)
            try c.encode(id, forKey: .node)
        case let .set(id, property, value):
            try c.encode("set", forKey: .op)
            try c.encode(id, forKey: .node)
            try c.encode(property, forKey: .property)
            try c.encodeIfPresent(value, forKey: .value)
        case let .publish(asset, version):
            try c.encode("publish", forKey: .op)
            try c.encode(asset, forKey: .asset)
            try c.encode(version, forKey: .version)
        case let .retract(asset, version):
            try c.encode("retract", forKey: .op)
            try c.encode(asset, forKey: .asset)
            try c.encode(version, forKey: .version)
        }
    }
}

/// A list of ops applied whole or not at all, from one workspace, named for
/// the Undo menu (§6.4, rules 1 and 2).
public struct Transaction: Sendable, Hashable, Codable {
    public var ops: [Op]
    public var origin: Workspace
    public var label: String
    /// The document it belongs to, whose ⌘Z reaches it: a path in the project.
    public var document: String?
    /// Whether it goes on the history. Publishing doesn't, as saving doesn't.
    public var undoable: Bool

    public init(_ ops: [Op], origin: Workspace, label: String, document: String? = nil, undoable: Bool = true) {
        self.ops = ops
        self.origin = origin
        self.label = label
        self.document = document
        self.undoable = undoable
    }
}

public struct GraphError: LocalizedError, Equatable {
    /// Which op was refused, from 0.
    public let op: Int
    public let reason: String

    public var errorDescription: String? { "Op \(op + 1) was refused: \(reason). Nothing changed." }
}

/// The project: one graph that every workspace views and changes only by
/// transactions (§4). It holds what crosses workspaces — assets, their
/// versions, and the links that use them — while each document's own edits
/// stay in its core, as Proton's formats need.
@MainActor
@Observable
public final class ProjectGraph {
    public private(set) var nodes: [NodeID: Node] = [:]
    /// Bumped by every change.
    public private(set) var revision: UInt64 = 0
    /// The project folder: `project.json`, `blobs/`, and its documents.
    /// `nil` keeps it in memory, for tests.
    public let folder: URL?
    public let pool: AssetPool
    public internal(set) var history = History()
    /// The transactions applied, newest last: the last 200, for the agent
    /// and for tests.
    public private(set) var log: [Transaction] = []
    /// Why the project couldn't be read or saved, when it couldn't.
    public var problem: String?

    @ObservationIgnored private var listeners: [UUID: @MainActor (Asset, AssetVersion) -> Void] = [:]
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Changed since `project.json` was last written.
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored static let signposter = OSSignposter(subsystem: "dev.razeen.aether", category: "graph")

    public init(folder: URL?, nodes: [Node] = []) {
        self.folder = folder
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        pool = AssetPool(blobs: folder?.appending(path: "blobs", directoryHint: .isDirectory))
    }

    /// The project's name: its folder's, without `.aether`.
    public var name: String { folder.map { $0.deletingPathExtension().lastPathComponent } ?? "Untitled" }

    // MARK: Applying

    /// Apply `tx` whole or not at all: every op is checked against a copy of
    /// the graph first, and the first refused leaves the graph as it was.
    public func apply(_ tx: Transaction) throws {
        let inverse = try commit(tx)
        if tx.undoable { history.made(.project(tx, inverse: inverse)) }
    }

    /// A step a document made in its own history, and the project change
    /// made with it, if any: one step for ⌘Z (§6.4, rule 5).
    /// The step is kept even when its project change is refused, so the
    /// history stays in step with the document's.
    public func documentStepped(_ document: String, label: String, with tx: Transaction? = nil) throws {
        var attached: (tx: Transaction, inverse: Transaction)?
        var refused: Error?
        if let tx {
            do { attached = (tx, try commit(tx)) } catch { refused = error }
        }
        history.made(.document(document, label: label, attached: attached))
        if let refused { throw refused }
    }

    @discardableResult
    private func commit(_ tx: Transaction) throws -> Transaction {
        let state = Self.signposter.beginInterval("apply", "\(tx.ops.count) ops")
        defer { Self.signposter.endInterval("apply", state) }
        var scratch = nodes
        var inverse: [Op] = []
        inverse.reserveCapacity(tx.ops.count)
        for (index, op) in tx.ops.enumerated() {
            do {
                inverse.append(try Self.mutate(&scratch, op))
            } catch let reason as Refusal {
                throw GraphError(op: index, reason: reason.text)
            }
        }
        nodes = scratch
        revision &+= 1
        unsaved = true
        log.append(tx)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        scheduleSave()
        for case let .publish(id, version) in tx.ops {
            guard let asset = asset(id) else { continue }
            for listener in listeners.values { listener(asset, version) }
        }
        return Transaction(inverse.reversed(), origin: tx.origin, label: tx.label, document: tx.document, undoable: tx.undoable)
    }

    private struct Refusal: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// `op` applied to `nodes`; answers its inverse.
    private static func mutate(_ nodes: inout [NodeID: Node], _ op: Op) throws -> Op {
        switch op {
        case .insert(let node):
            guard nodes[node.id] == nil else { throw Refusal("there is already a node \(node.id)") }
            try check(node, in: nodes)
            nodes[node.id] = node
            return .remove(node.id)
        case .remove(let id):
            guard let node = nodes[id] else { throw Refusal("there is no node \(id)") }
            if node.kind == .asset, let user = nodes.values.first(where: { $0.kind == .link && $0["asset"]?.string == id.description }) {
                throw Refusal("\(node["name"]?.string ?? "the asset") is still used by \(user["document"]?.string ?? "a document")")
            }
            nodes[id] = nil
            return .insert(node)
        case let .set(id, property, value):
            guard var node = nodes[id] else { throw Refusal("there is no node \(id)") }
            let old = node[property]
            node[property] = value
            try check(node, in: nodes)
            nodes[id] = node
            return .set(id, property: property, value: old)
        case let .publish(id, version):
            guard var node = nodes[id.node], node.kind == .asset else { throw Refusal("there is no asset \(id)") }
            let next = (node.versions.last?.number ?? 0) + 1
            guard version.number == next else { throw Refusal("the next version is \(next), not \(version.number)") }
            node.versions.append(version)
            nodes[id.node] = node
            return .retract(id, version: version.number)
        case let .retract(id, number):
            guard var node = nodes[id.node], node.kind == .asset, let last = node.versions.last else { throw Refusal("there is no asset \(id) with versions") }
            guard last.number == number else { throw Refusal("only the newest version, \(last.number), can be taken off") }
            if nodes.values.contains(where: { $0.kind == .link && $0["asset"]?.string == id.description && $0["pinned"]?.int == number }) {
                throw Refusal("version \(number) is pinned")
            }
            node.versions.removeLast()
            nodes[id.node] = node
            return .publish(id, last)
        }
    }

    /// What every node of a kind must have.
    private static func check(_ node: Node, in nodes: [NodeID: Node]) throws {
        for property in ["name", "document"] where node.kind == .asset && node[property]?.string == nil {
            throw Refusal("an asset needs a \(property)")
        }
        guard node.kind == .link else { return }
        for property in ["document", "slot"] where node[property]?.string == nil {
            throw Refusal("a link needs a \(property)")
        }
        guard let raw = node["asset"]?.string, let id = UUID(uuidString: raw), let asset = nodes[NodeID(id)], asset.kind == .asset else {
            throw Refusal("a link needs an asset that is there")
        }
        if let pinned = node["pinned"]?.int, !asset.versions.contains(where: { $0.number == pinned }) {
            throw Refusal("\(asset["name"]?.string ?? "the asset") has no version \(pinned)")
        }
    }

    // MARK: Undo, document by document

    /// Undo the newest step of `document`: its own (by `documentUndo`, which
    /// answers whether there was one) or a project step made in it, whichever
    /// came last. Answers whether anything was undone.
    @discardableResult
    public func undo(in document: String?, documentUndo: () -> Bool) -> Bool {
        while let entry = history.takeDone(in: document) {
            switch entry.kind {
            case let .project(_, inverse):
                guard (try? commit(inverse)) != nil else { continue }
            case let .document(_, _, attached):
                guard documentUndo() else { continue }
                if let attached { _ = try? commit(attached.inverse) }
            }
            history.undid(entry)
            return true
        }
        return documentUndo()
    }

    /// Redo only what the history undid: a project step made since drops the
    /// document's redo, though its core still holds the step.
    @discardableResult
    public func redo(in document: String?, documentRedo: () -> Bool) -> Bool {
        while let entry = history.takeUndone(in: document) {
            switch entry.kind {
            case let .project(tx, _):
                guard (try? commit(tx)) != nil else { continue }
            case let .document(_, _, attached):
                guard documentRedo() else { continue }
                if let attached { _ = try? commit(attached.tx) }
            }
            history.redid(entry)
            return true
        }
        return false
    }

    /// What ⌘Z would undo in `document`, for the Edit menu.
    public func undoLabel(in document: String?) -> String? { history.done.last { $0.document == document }?.label }
    public func redoLabel(in document: String?) -> String? { history.undone.last { $0.document == document }?.label }

    /// A document closed: its own history went with it, so its steps leave
    /// the project's too.
    public func forget(document: String) {
        history.forget(document)
    }

    /// A document saved: the links made with its steps are part of it now.
    public func documentSaved(_ document: String) {
        history.markSaved(document)
    }

    /// A document let go with changes not saved: the project changes made
    /// with those changes are taken back, and those of saved steps undone
    /// are made again, so the links match the file. Otherwise a link to a
    /// layer or node that was never saved would stay, and fasten on to the
    /// next one given its id.
    public func discard(document: String) {
        let (takeBack, makeAgain) = history.unsaved(document)
        for tx in takeBack + makeAgain { _ = try? commit(tx) }
        history.forget(document)
    }

    // MARK: Listening

    /// `handler` is told of every version published, on the main actor, in
    /// the same turn as the transaction; until the answer is let go.
    public func onPublish(_ handler: @escaping @MainActor (Asset, AssetVersion) -> Void) -> Listening {
        let key = UUID()
        listeners[key] = handler
        return Listening { [weak self] in self?.listeners[key] = nil }
    }

    // MARK: Paths

    /// How the project names a document: its path inside the folder, or the
    /// whole path when it is elsewhere.
    public func path(of url: URL) -> String {
        let file = url.standardizedFileURL.path
        guard let folder else { return file }
        let root = folder.standardizedFileURL.path
        return file.hasPrefix(root + "/") ? String(file.dropFirst(root.count + 1)) : file
    }

    public func url(of path: String) -> URL {
        if path.hasPrefix("/") || folder == nil { return URL(fileURLWithPath: path) }
        return folder!.appending(path: path)
    }

    // MARK: Saving

    /// Write `project.json` a moment after the last change.
    private func scheduleSave() {
        guard folder != nil else { return }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write `project.json` now, whole and atomically, if anything changed:
    /// a project nothing was linked in leaves no file behind.
    public func saveNow() {
        saving?.cancel()
        saving = nil
        guard let folder, unsaved else { return }
        do {
            try ProjectFile(name: name, nodes: Array(nodes.values)).write(into: folder)
            unsaved = false
            problem = nil
        } catch {
            problem = "Couldn’t save the project: \(error.localizedDescription)"
        }
    }

    /// The project in `folder`, from its `project.json`; an empty one when
    /// there is none yet.
    public static func open(_ folder: URL) throws -> ProjectGraph {
        ProjectGraph(folder: folder, nodes: try ProjectFile.read(from: folder)?.nodes ?? [])
    }

    /// A new project in `folder` (`Name.aether`, a package): its
    /// `Canvases/`, `Flows/` and `project.json`. A project already there is
    /// opened as it is, never written over.
    public static func create(_ folder: URL) throws -> ProjectGraph {
        if FileManager.default.fileExists(atPath: folder.appending(path: ProjectFile.name).path) { return try open(folder) }
        for part in ["Canvases", "Flows"] {
            try FileManager.default.createDirectory(at: folder.appending(path: part, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        let project = ProjectGraph(folder: folder)
        try ProjectFile(name: project.name, nodes: []).write(into: folder)
        return project
    }

    /// Whether `folder` is a project: a `.aether` package, one with a
    /// `project.json`, or a folder of `Canvases/` or `Flows/` to start one in.
    public nonisolated static func isProject(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        return folder.pathExtension == "aether" || ["project.json", "Canvases", "Flows"].contains { fm.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// Where the project's canvases and flows go.
    public var canvasesFolder: URL? { folder?.appending(path: "Canvases", directoryHint: .isDirectory) }
    public var flowsFolder: URL? { folder?.appending(path: "Flows", directoryHint: .isDirectory) }
}

/// A listener held: let go, it stops.
@MainActor
public final class Listening {
    private let stop: @MainActor () -> Void

    init(_ stop: @escaping @MainActor () -> Void) {
        self.stop = stop
    }

    isolated deinit {
        stop()
    }
}
