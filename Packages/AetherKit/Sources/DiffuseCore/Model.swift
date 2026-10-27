import CoreGraphics
import Foundation

// The shapes proton-diffuse's serde types define, decoded as the core hands
// them over. The core stays the authority: these are read-only views of what
// it said, and every change goes back to it as an op.

/// A `.flow.json`.
public struct Flow: Codable, Equatable, Sendable {
    public var format: Int
    public var note: String?
    public var outputs: String?
    public var nodes: [FlowNode]
    public var links: [FlowLink]

    public init(format: Int = 1, note: String? = nil, outputs: String? = nil, nodes: [FlowNode] = [], links: [FlowLink] = []) {
        self.format = format
        self.note = note
        self.outputs = outputs
        self.nodes = nodes
        self.links = links
    }

    enum CodingKeys: String, CodingKey { case format, note, outputs, nodes, links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        outputs = try c.decodeIfPresent(String.self, forKey: .outputs)
        nodes = try c.decodeIfPresent([FlowNode].self, forKey: .nodes) ?? []
        links = try c.decodeIfPresent([FlowLink].self, forKey: .links) ?? []
    }

    public func node(_ id: String) -> FlowNode? { nodes.first { $0.id == id } }

    /// The link into input port `port` (`node:name`), if any.
    public func link(into port: String) -> FlowLink? { links.first { $0.to == port } }
}

public struct FlowNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var at: [Double]
    public var values: [String: JSONValue]
    public var seed: SeedMode?
    public var bypass: Bool?

    public var position: CGPoint { CGPoint(x: at.first ?? 0, y: at.count > 1 ? at[1] : 0) }
    public var isBypassed: Bool { bypass ?? false }

    enum CodingKeys: String, CodingKey { case id, type, at, values, seed, bypass }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        at = try c.decode([Double].self, forKey: .at)
        values = try c.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        seed = try c.decodeIfPresent(SeedMode.self, forKey: .seed)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass)
    }
}

/// A link from an output port to an input port, each `node:name`.
public struct FlowLink: Codable, Hashable, Sendable {
    public var from: String
    public var to: String

    public var source: FlowPort? { FlowPort(from) }
    public var target: FlowPort? { FlowPort(to) }
}

/// A port, read from `node:name`.
public struct FlowPort: Hashable, Sendable {
    public var node: String
    public var name: String

    public init(node: String, name: String) {
        self.node = node
        self.name = name
    }

    public init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let node = String(text[..<colon]), name = String(text[text.index(after: colon)...])
        guard !node.isEmpty, !name.isEmpty else { return nil }
        self.init(node: node, name: name)
    }

    public var text: String { "\(node):\(name)" }
}

public enum SeedMode: String, Codable, CaseIterable, Sendable {
    case fixed, increment, random

    public var title: String {
        switch self {
        case .fixed: "Fixed"
        case .increment: "Increment"
        case .random: "Random"
        }
    }
}

/// What the core says a batch of ops did.
public struct Applied: Codable, Sendable {
    public var changed: Bool
    public var added: [String]
}

/// One thing that stops a flow running.
public struct Problem: Codable, Hashable, Sendable {
    public var node: String?
    public var input: String?
    public var message: String
}

// MARK: - The catalogue

/// What a server can run.
public struct Catalogue: Codable, Sendable {
    public var version: Int
    public var types: [String]
    public var nodes: [NodeType]
    public var lists: [String: [String]]

    enum CodingKeys: String, CodingKey { case version, types, nodes, lists }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        types = try c.decode([String].self, forKey: .types)
        nodes = try c.decode([NodeType].self, forKey: .nodes)
        lists = try c.decodeIfPresent([String: [String]].self, forKey: .lists) ?? [:]
    }

    public func node(_ type: String) -> NodeType? { nodes.first { $0.type == type } }

    /// The node types by the group the editor lists them under, in the
    /// catalogue's order.
    public var groups: [(name: String, nodes: [NodeType])] {
        var order: [String] = []
        var by: [String: [NodeType]] = [:]
        for node in nodes {
            if by[node.group] == nil { order.append(node.group) }
            by[node.group, default: []].append(node)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    /// What a choice filled `from` a list can be: the catalogue's own list or
    /// one of the server's model lists. `nil` when neither is known yet.
    public func choices(from: String, models: ModelLists?) -> [String]? {
        if let list = lists[from] { return list }
        return models?.lists[from]?.map(\.name)
    }
}

public struct NodeType: Codable, Identifiable, Sendable {
    public var type: String
    public var title: String
    public var group: String
    public var inputs: [NodeInput]
    public var outputs: [NodeOutput]

    public var id: String { type }

    enum CodingKeys: String, CodingKey { case type, title, group, inputs, outputs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        group = try c.decode(String.self, forKey: .group)
        inputs = try c.decodeIfPresent([NodeInput].self, forKey: .inputs) ?? []
        outputs = try c.decodeIfPresent([NodeOutput].self, forKey: .outputs) ?? []
    }

    /// Inputs a link comes into.
    public var sockets: [NodeInput] { inputs.filter(\.isSocket) }
    /// Inputs set on the node.
    public var fields: [NodeInput] { inputs.filter { !$0.isSocket } }
    /// A node that makes nothing a link can carry is what a run is run for.
    public var isOutput: Bool { outputs.isEmpty }
}

public struct NodeInput: Codable, Sendable {
    public var name: String
    /// The socket type a link must carry; `nil` for a field.
    public var type: String?
    /// For a field: `int`, `float`, `text`, `choice`, `seed` or `upload`.
    public var kind: String?
    public var optional: Bool?
    public var multiline: Bool?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var `default`: JSONValue?
    public var from: String?

    public var isSocket: Bool { type != nil }
    public var fieldKind: FieldKind { FieldKind(rawValue: kind ?? "") ?? .other }
    public var isOptional: Bool { optional ?? false }
}

public enum FieldKind: String, Sendable {
    case int, float, text, choice, seed, upload, other
}

public struct NodeOutput: Codable, Sendable {
    public var name: String
    public var type: String
}

/// The models a server can load, list by list.
public struct ModelLists: Codable, Sendable {
    public var lists: [String: [ModelFile]]

    public init(from decoder: Decoder) throws {
        lists = try decoder.singleValueContainer().decode([String: [ModelFile]].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(lists)
    }
}

public struct ModelFile: Codable, Sendable, Hashable {
    public var name: String
    public var family: String?
    public var bytes: UInt64
}

// MARK: - Runs

/// One event of a run, as the gateway streams them.
public enum RunEvent: Decodable, Sendable, Equatable {
    case queued(position: Int)
    case started
    case node(id: String, state: NodeRunState)
    case progress(id: String, step: Int, steps: Int)
    case preview(id: String, step: Int, jpeg: String)
    case image(id: String, image: String, index: Int, width: Int, height: Int)
    case error(id: String?, error: String, message: String)
    case done(seconds: Double)
    case cancelled

    enum CodingKeys: String, CodingKey {
        case event, position, id, state, step, steps, jpeg, image, index, width, height, error, message, seconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .event) {
        case "queued": self = .queued(position: try c.decode(Int.self, forKey: .position))
        case "started": self = .started
        case "node": self = .node(id: try c.decode(String.self, forKey: .id), state: try c.decode(NodeRunState.self, forKey: .state))
        case "progress":
            self = .progress(id: try c.decode(String.self, forKey: .id), step: try c.decode(Int.self, forKey: .step), steps: try c.decode(Int.self, forKey: .steps))
        case "preview":
            self = .preview(id: try c.decode(String.self, forKey: .id), step: try c.decode(Int.self, forKey: .step), jpeg: try c.decode(String.self, forKey: .jpeg))
        case "image":
            self = .image(
                id: try c.decode(String.self, forKey: .id), image: try c.decode(String.self, forKey: .image),
                index: try c.decode(Int.self, forKey: .index), width: try c.decode(Int.self, forKey: .width),
                height: try c.decode(Int.self, forKey: .height))
        case "error":
            self = .error(id: try c.decodeIfPresent(String.self, forKey: .id), error: try c.decode(String.self, forKey: .error), message: try c.decode(String.self, forKey: .message))
        case "done": self = .done(seconds: try c.decode(Double.self, forKey: .seconds))
        case "cancelled": self = .cancelled
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "unknown event \(other)")
        }
    }

    public var ends: Bool {
        switch self {
        case .done, .error, .cancelled: true
        default: false
        }
    }
}

public enum NodeRunState: String, Codable, Sendable {
    case running, cached, done
}

/// A run, queued.
public struct Queued: Codable, Sendable {
    public var run: String
    public var position: Int
}

/// How the gateway and forge are.
public struct Health: Codable, Sendable, Equatable {
    public var state: HealthState
    public var url: String?
    public var ms: Int?
    public var status: ServerStatus?
    public var message: String

    public static let looking = Health(state: .looking, url: nil, ms: nil, status: nil, message: "Looking for the image server")
}

public enum HealthState: String, Codable, Sendable {
    case looking, serving, offline, badKey, noKey, unreachable, failing
}

public struct ServerStatus: Codable, Sendable, Equatable {
    public struct GPU: Codable, Sendable, Equatable {
        public var name: String
        public var total: UInt64
        public var used: UInt64
    }
    public struct Loaded: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: UInt64
    }
    public var gpu: GPU
    public var loaded: [Loaded]?
    public var queue: [String]?
    public var running: String?
}
