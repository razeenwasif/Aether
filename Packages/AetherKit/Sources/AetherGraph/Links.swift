import Foundation

/// Something one workspace makes that others use, read from its node.
public struct Asset: Identifiable, Hashable, Sendable {
    public let id: AssetID
    public var name: String
    /// The workspace that makes it.
    public var source: Workspace
    /// The document that makes it: a path in the project.
    public var document: String
    public var versions: [AssetVersion]

    public var newest: AssetVersion? { versions.last }

    init?(_ node: Node) {
        guard node.kind == .asset, let name = node["name"]?.string, let document = node["document"]?.string,
              let source = node["source"]?.string.flatMap(Workspace.init(rawValue:)) else { return nil }
        id = AssetID(node.id)
        self.name = name
        self.source = source
        self.document = document
        versions = node.versions
    }
}

/// A use of an asset: a canvas layer, a Load Image's picture.
public struct AssetLink: Identifiable, Hashable, Sendable {
    public let id: NodeID
    public var asset: AssetID
    /// The workspace that uses it.
    public var consumer: Workspace
    /// The document that uses it: a path in the project.
    public var document: String
    /// Where in the document: see `Slot`.
    public var slot: String
    /// The version it keeps; `nil` follows the newest.
    public var pinned: Int?
    /// The version it last took.
    public var shown: Int?

    init?(_ node: Node) {
        guard node.kind == .link, let raw = node["asset"]?.string, let asset = UUID(uuidString: raw),
              let consumer = node["consumer"]?.string.flatMap(Workspace.init(rawValue:)),
              let document = node["document"]?.string, let slot = node["slot"]?.string else { return nil }
        id = node.id
        self.asset = AssetID(NodeID(asset))
        self.consumer = consumer
        self.document = document
        self.slot = slot
        pinned = node["pinned"]?.int
        shown = node["shown"]?.int
    }
}

/// Where a link lands in a document.
public enum Slot {
    /// A canvas layer, by its id.
    public static func layer(_ id: UInt32) -> String { "layer:\(id)" }
    public static func layer(of slot: String) -> UInt32? {
        slot.hasPrefix("layer:") ? UInt32(slot.dropFirst(6)) : nil
    }

    /// A design's image layer, by its page and its id.
    public static func design(page: String, layer: String) -> String { "design:\(page)/\(layer)" }
    public static func design(of slot: String) -> (page: String, layer: String)? {
        guard slot.hasPrefix("design:"), let cut = slot.firstIndex(of: "/") else { return nil }
        return (String(slot[slot.index(slot.startIndex, offsetBy: 7)..<cut]), String(slot[slot.index(after: cut)...]))
    }

    /// A flow node's picture field.
    public static func input(node: String, field: String) -> String { "input:\(node)/\(field)" }
    public static func input(of slot: String) -> (node: String, field: String)? {
        guard slot.hasPrefix("input:"), let cut = slot.firstIndex(of: "/") else { return nil }
        return (String(slot[slot.index(slot.startIndex, offsetBy: 6)..<cut]), String(slot[slot.index(after: cut)...]))
    }
}

extension ProjectGraph {
    /// Every asset, by name.
    public var assets: [Asset] {
        nodes.values.compactMap(Asset.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var links: [AssetLink] { nodes.values.compactMap(AssetLink.init) }

    public func asset(_ id: AssetID) -> Asset? { nodes[id.node].flatMap(Asset.init) }

    /// The asset a document makes, if it makes one.
    public func asset(madeBy document: String) -> Asset? {
        nodes.values.lazy.compactMap(Asset.init).first { $0.document == document }
    }

    public func links(to asset: AssetID) -> [AssetLink] { links.filter { $0.asset == asset } }
    public func links(in document: String) -> [AssetLink] { links.filter { $0.document == document } }
    public func link(in document: String, slot: String) -> AssetLink? { links.first { $0.document == document && $0.slot == slot } }

    /// The version a link shows: the one it keeps, or the newest.
    public func version(for link: AssetLink) -> AssetVersion? {
        guard let asset = asset(link.asset) else { return nil }
        return link.pinned.map { n in asset.versions.first { $0.number == n } } ?? asset.newest
    }

    // MARK: Changes

    /// The asset `document` makes, made the first time it's asked for.
    public func asset(madeBy document: String, named name: String, in source: Workspace) throws -> Asset {
        if let asset = asset(madeBy: document) { return asset }
        let node = Node(kind: .asset, properties: ["name": .string(name), "source": .string(source.rawValue), "document": .string(document)])
        try apply(Transaction([.insert(node)], origin: source, label: "Make \(name) an asset", document: document, undoable: false))
        return asset(AssetID(node.id))!
    }

    /// A new version of `asset`: its bytes already in the pool as `blob`.
    /// Not an undo step, as saving isn't; every link following it is told.
    @discardableResult
    public func publish(_ id: AssetID, blob: String, width: Int, height: Int, note: String? = nil) throws -> AssetVersion {
        guard let asset = asset(id) else { throw GraphError(op: 0, reason: "there is no asset \(id)") }
        if let newest = asset.newest, newest.blob == blob { return newest }
        let version = AssetVersion(number: (asset.newest?.number ?? 0) + 1, blob: blob, width: width, height: height, note: note)
        try apply(Transaction([.publish(id, version)], origin: asset.source, label: "Publish \(asset.name) v\(version.number)", document: asset.document, undoable: false))
        return version
    }

    /// The op that links `asset` into `slot` of `document`, following the
    /// newest version; for a transaction of its own or one made with a
    /// document step.
    public func linkOp(_ asset: AssetID, into document: String, slot: String, by consumer: Workspace) -> Op {
        .insert(Node(kind: .link, properties: [
            "asset": .string(asset.description), "consumer": .string(consumer.rawValue),
            "document": .string(document), "slot": .string(slot),
            "shown": .int(self.asset(asset)?.newest?.number ?? 0),
        ]))
    }

    /// Keep `version` of the asset, or follow the newest with `nil`. An undo
    /// step in the link's document.
    public func pin(_ link: AssetLink, to version: Int?) throws {
        guard link.pinned != version else { return }
        let label = version.map { "Keep Version \($0)" } ?? "Follow the Newest"
        try apply(Transaction([.set(link.id, property: "pinned", value: version.map(PropertyValue.int))], origin: link.consumer, label: label, document: link.document))
    }

    /// The link taken away; what it shows stays, no longer updated. An undo
    /// step in the link's document.
    public func unlink(_ link: AssetLink) throws {
        try apply(Transaction([.remove(link.id)], origin: link.consumer, label: "Unlink", document: link.document))
    }

    /// Which version a link took, for when its document opens again.
    public func took(_ version: Int, for link: AssetLink) {
        guard link.shown != version, nodes[link.id] != nil else { return }
        try? apply(Transaction([.set(link.id, property: "shown", value: .int(version))], origin: link.consumer, label: "Take v\(version)", document: link.document, undoable: false))
    }

    /// A document saved somewhere else: its assets and links, and its steps,
    /// go with it.
    public func move(document: String, to path: String, by origin: Workspace) {
        guard document != path else { return }
        let ops: [Op] = nodes.values.filter { $0["document"]?.string == document }.map { .set($0.id, property: "document", value: .string(path)) }
        if !ops.isEmpty { try? apply(Transaction(ops, origin: origin, label: "Move \(document)", document: path, undoable: false)) }
        history.move(document, to: path)
    }
}
