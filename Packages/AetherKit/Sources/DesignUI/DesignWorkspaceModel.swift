import AetherGraph
import AppKit
import DesignCore
import Foundation
import ImageIO
import Observation

/// What a change at a narrower breakpoint, or in one option of a
/// component's prop, is said in: the layer's `at` or `when`, under `key`.
public struct DesignOverrideTarget: Equatable, Sendable {
    public var field: String
    public var key: String
    /// For people: Mobile, Secondary.
    public var name: String
}

/// Which list the navigator shows.
public enum DesignNavigatorTab: String, CaseIterable, Sendable {
    case layers = "Layers"
    case tokens = "Tokens"
}

/// The Design workspace's state: the designs in the project's `Designs/`,
/// the one open, the page on screen, the breakpoint being edited, the layer
/// chosen, and the panels. A design's steps are steps of the project's one
/// history, so an image placed and the link it follows undo together.
@MainActor
@Observable
public final class DesignWorkspaceModel {
    /// Where designs go: the project's `Designs/`, a folder a design.
    public private(set) var folder: URL
    public private(set) var designs: [DesignFound] = []
    public private(set) var document: DesignDocument?
    /// The page on screen, by id.
    public var pageID: String? {
        didSet { if pageID != oldValue { selection = nil; breakpoint = nil; componentID = nil; fitRequest &+= 1 } }
    }
    /// The component being edited in the page's place, by id.
    public private(set) var componentID: String?
    /// The option of the component's prop the inspector edits
    /// (`variant=secondary`); nil is the component as written. Choosing a
    /// layer on an option's artboard edits that option.
    public var variant: String?
    /// The breakpoint a component is seen and edited at, by the id it has on
    /// the page that places it; nil, the widest. A narrower one is what's
    /// edited, ahead of an option.
    public var componentBreakpoint: String?
    /// The breakpoint the inspector edits, by id; nil is the widest, the
    /// page's own. Choosing a layer on an artboard edits that artboard's.
    public var breakpoint: String?
    /// The layer chosen, by id.
    public var selection: String?
    public var navigatorTab: DesignNavigatorTab = .layers
    public var navigatorOpen = true
    public var inspectorOpen = true
    /// The code drawer (⌘/): the chosen layer as HTML and CSS.
    public var codeOpen = false
    public var notice: String? {
        didSet { noticeIsGood = false }
    }
    public private(set) var noticeIsGood = false
    /// The name the home page's form makes a design with.
    public var newName = "Lumen"
    /// Bumped to have the canvas show every artboard.
    public private(set) var fitRequest = 0
    /// Bumped to put the keys in the inspector's text field: a text layer
    /// double-clicked on the artboard.
    public private(set) var editTextRequest = 0
    /// Bumped when a picture's file is written again, so it's read again.
    public private(set) var pictureRevision = 0

    /// The project the design is part of: its history, its assets.
    public var project: ProjectGraph? {
        didSet { listening = project?.onPublish { [weak self] asset, version in self?.published(asset, version) } }
    }
    /// Open what makes an asset, in the workspace that makes it.
    @ObservationIgnored public var showSource: ((Asset) -> Void)?
    @ObservationIgnored private var listening: Listening?
    /// Pictures being written, one after another.
    @ObservationIgnored private(set) var writing: Task<Void, Never>?
    /// What the sync folder's files couldn't take the last time one was read
    /// back, in words.
    public private(set) var syncNotes: [String] = []
    /// The look, once a second, for a file of the sync folder edited
    /// outside Aether.
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// What each file of the sync folder held when it was last written or
    /// read, by where it is in it.
    @ObservationIgnored private var known: [String: String] = [:]

    public init(folder: URL) {
        self.folder = folder
        refreshList()
    }

    /// The page on screen, or the component being edited, as a tree of
    /// layers.
    public var page: DesignPage? {
        if let componentID { return document?.component(componentID)?.asPage() }
        return pageID.flatMap { document?.page($0) }
    }
    /// The component being edited.
    public var component: DesignComponent? { componentID.flatMap { document?.component($0) } }
    /// The tree as the breakpoint or option being edited has it.
    public var pageHere: DesignPage? {
        if let component { return component.asPage(variant).with(breakpoints: componentBreakpoints).at(componentBreakpoint) }
        return page?.at(breakpoint)
    }

    /// The breakpoints a component is seen at, widest first: those of the
    /// first page that places it, or of the first page.
    public var componentBreakpoints: [DesignBreakpoint] {
        guard let document, let componentID else { return [] }
        let pages = document.view.pages.compactMap { document.page($0.id) }
        let placing = pages.first { $0.layers.contains { $0.component == componentID } }
            ?? pages.first { page in page.layers.contains { $0.kind == .instance && document.component($0.component)?.layers.contains { $0.component == componentID } == true } }
        return (placing ?? pages.first)?.widestFirst ?? []
    }
    /// The chosen layer, as the breakpoint or option being edited has it.
    public var chosen: DesignLayer? { selection.flatMap { pageHere?.layer($0) } }
    public var resolver: DesignResolver { DesignResolver(tokens: document?.tokens ?? []) }

    /// The breakpoint being edited when it's not the widest, or the option
    /// of a component's prop: where a change is what it says, not the
    /// layer's own.
    public var overriding: DesignOverrideTarget? {
        if let component {
            let points = componentBreakpoints
            if let at = componentBreakpoint, at != points.first?.id, let point = points.first(where: { $0.id == at }) {
                return DesignOverrideTarget(field: "at", key: point.id, name: point.name)
            }
            guard let variant, let option = component.options.first(where: { $0.key == variant }) else { return nil }
            return DesignOverrideTarget(field: "when", key: variant, name: option.name)
        }
        guard let page, let breakpoint, let point = page.breakpoints.first(where: { $0.id == breakpoint }),
              point.id != page.widestFirst.first?.id else { return nil }
        return DesignOverrideTarget(field: "at", key: point.id, name: point.name)
    }

    /// What `layer` says for the breakpoint or option being edited.
    private func said(by layer: DesignLayer, for target: DesignOverrideTarget) -> DesignOverride? {
        target.field == "when" ? layer.when[target.key] : layer.at[target.key]
    }

    /// How the project names the design open.
    public var documentPath: String? {
        guard let project, let document else { return nil }
        return project.path(of: document.url)
    }

    /// Point at another project's `Designs/`, closing the design open.
    public func switchFolder(to folder: URL) {
        replace(with: nil)
        pageID = nil
        self.folder = folder
        refreshList()
    }

    public func refreshList() {
        designs = DesignDocument.found(in: folder)
    }

    /// A new design from the starter, named on the home page's form, in a
    /// folder of its own, opened.
    public func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return notice = "Name the design first." }
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        var dir = folder.appending(path: slug, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = folder.appending(path: "\(slug)_\(n)", directoryHint: .isDirectory)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try DesignDocument.create(named: name, in: dir)
            refreshList()
            open(dir)
        } catch {
            notice = "Couldn’t make \(name): \(DesignDocument.describe(error))"
        }
    }

    public func open(_ url: URL) {
        do {
            let doc = try DesignDocument(url: url)
            replace(with: doc)
            pageID = doc.view.pages.first?.id
            selection = nil
            breakpoint = nil
            fitRequest &+= 1
            if let problem = doc.view.problems.first { notice = problem }
            syncImages()
            // Edits made to the folder while the design was closed come in
            // as steps, before the next save writes over them.
            checkSync()
            watch()
        } catch {
            notice = "Couldn’t open \(url.lastPathComponent): \(DesignDocument.describe(error))"
        }
    }

    /// Back to the designs: refused while anything is unsaved, which says so.
    public func close() {
        guard let document else { return }
        if !document.unsaved.isEmpty {
            notice = "\(document.name) has unsaved changes: save them (⌘S) first."
            return
        }
        replace(with: nil)
        pageID = nil
        refreshList()
    }

    /// The design open let go: its history goes with it, so its steps leave
    /// the project's; with changes not saved, the links made with them go
    /// too.
    private func replace(with next: DesignDocument?) {
        if let old = document, old !== next, let project {
            let path = project.path(of: old.url)
            if old.unsaved.isEmpty { project.forget(document: path) } else { project.discard(document: path) }
        }
        watching?.cancel()
        watching = nil
        known = [:]
        syncNotes = []
        document = next
    }

    public func fit() { fitRequest &+= 1 }

    /// The artboard's double-click: choose the layer, and for text, type.
    public func editText(_ id: String) {
        selection = id
        if page?.layer(id)?.kind == .text {
            inspectorOpen = true
            editTextRequest &+= 1
        }
    }

    /// The frame the chosen layer is in, chosen instead.
    public func chooseParent() {
        guard let id = selection, let up = page?.parent(of: id) else { return }
        selection = up.id
    }

    // MARK: Editing

    /// Ops on the page on screen, or the component being edited, as one
    /// step, and the project change made with it, if any, as part of the
    /// same step.
    @discardableResult
    private func apply(_ ops: [DesignOp], label: String, with tx: AetherGraph.Transaction? = nil) -> Bool {
        guard let document else { return false }
        let changed: Bool
        if let componentID {
            changed = document.apply(ops, toComponent: componentID, label: label)
        } else if let pageID {
            changed = document.apply(ops, toPage: pageID, label: label)
        } else {
            return false
        }
        if let refusal = document.refusal { notice = refusal }
        if changed { stepped(label, with: tx) }
        return changed
    }

    /// A step the design made, on the project's history.
    private func stepped(_ label: String, with tx: AetherGraph.Transaction? = nil) {
        guard let project, let path = documentPath else { return }
        do {
            try project.documentStepped(path, label: label, with: tx)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func path(_ id: String, _ keys: [String] = []) -> [String] {
        ["layers", "#\(id)"] + keys
    }

    public func rename(_ id: String, to name: String) {
        guard let layer = page?.layer(id) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        apply([.set(path(id, ["name"]), name.isEmpty || name == id ? nil : name)], label: "Rename \(layer.label)")
    }

    public func setText(_ id: String, _ text: String) {
        guard let layer = page?.layer(id), layer.text != text else { return }
        apply([.set(path(id, ["text"]), text)], label: "Edit \(layer.label)")
    }

    /// A field of a layer — `["w"]`, `["layout", "gap"]`, `["style",
    /// "fill"]` — as the breakpoint being edited says it: the layer's own at
    /// the widest, else what that breakpoint says. Nil says nothing: at a
    /// narrower breakpoint, that's the wider one's again.
    public func set(_ id: String, _ keys: [String], to value: Any?, label what: String) {
        guard let layer = page?.layer(id) else { return }
        guard let point = overriding else {
            apply([.set(path(id, keys), value)], label: "\(what) of \(layer.label)")
            return
        }
        let label = "\(what) of \(layer.label) on \(point.name)"
        if said(by: layer, for: point) != nil {
            apply([.set(path(id, [point.field, point.key] + keys), value)], label: label)
        } else if let value {
            // It says nothing of it yet: what it says, made.
            let said = keys.reversed().reduce(value) { inner, key in [key: inner] as [String: Any] }
            apply([.set(path(id, [point.field, point.key]), said)], label: label)
        }
    }

    /// Whether the breakpoint being edited says the field at `keys` of `id`
    /// itself, rather than taking the wider one's.
    public func says(_ id: String, _ keys: [String]) -> Bool {
        guard let point = overriding, let layer = page?.layer(id), let over = said(by: layer, for: point) else { return false }
        return over.says(keys)
    }

    /// The field at `keys` as the wider breakpoint has it again.
    public func reset(_ id: String, _ keys: [String]) {
        guard says(id, keys) else { return }
        set(id, keys, to: nil, label: "Reset \(DesignWorkspaceModel.title(keys.last ?? ""))")
    }

    /// A width or height: `hug`, `fill`, points, or nil for the kind's own.
    public func setSize(_ id: String, width: Bool, to value: DesignVal?) {
        set(id, [width ? "w" : "h"], to: value?.json, label: width ? "Width" : "Height")
    }

    public func setNarrowest(_ id: String, to points: Double?) {
        set(id, ["minW"], to: points, label: "Narrowest")
    }

    /// Shown or hidden at the breakpoint being edited.
    public func setHidden(_ id: String, _ hidden: Bool) {
        // At the widest, not hidden is said by saying nothing.
        set(id, ["hidden"], to: hidden ? true : (overriding == nil ? nil : false), label: hidden ? "Hide" : "Show")
    }

    /// One of a frame's layout fields (`direction`, `gap`, `padH`, `padV`,
    /// `align`, `justify`, `wrap`), or nil to say nothing.
    public func setLayout(_ id: String, _ key: String, to value: Any?) {
        set(id, ["layout", key], to: value, label: Self.title(key))
    }

    /// One of a layer's style fields (`fill`, `stroke`, `radius`, `color`,
    /// `font`, `textAlign`, `opacity`, `fit`), or nil to say nothing.
    public func setStyle(_ id: String, _ key: String, to value: Any?) {
        set(id, ["style", key], to: value, label: Self.title(key))
    }

    static func title(_ key: String) -> String {
        switch key {
        case "padH": "Padding"
        case "padV": "Padding"
        case "textAlign": "Alignment"
        // As the inspector's row says it.
        case "color": "Colour"
        case "minW": "Narrowest"
        case "w": "Width"
        case "h": "Height"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// Where a new layer goes: inside the chosen frame at its end, or after
    /// the chosen layer in its frame, or at the end of the page.
    private func placeForNew(in page: DesignPage) -> (into: String, at: Int?) {
        if let chosen, chosen.kind == .frame { return (chosen.id, nil) }
        if let id = selection, let up = page.parent(of: id) {
            return (up.id, (up.children.firstIndex(of: id) ?? up.children.count - 1) + 1)
        }
        return (page.root, nil)
    }

    /// A new layer of `kind`, placed as `placeForNew` says, and chosen.
    public func add(_ kind: DesignKind) {
        guard let page else { return }
        let id = Self.fresh(kind.rawValue, in: page)
        var layer: [String: Any] = ["id": id, "kind": kind.rawValue]
        let tokens = Set(document?.tokens.map(\.name) ?? [])
        func token(_ name: String) -> String? { tokens.contains(name) ? name : nil }
        switch kind {
        case .frame:
            layer["name"] = "Frame"
            var layout: [String: Any] = ["padH": token("--space-4") ?? 16, "padV": token("--space-4") ?? 16, "gap": token("--space-2") ?? 8]
            layout["direction"] = "column"
            layer["layout"] = layout
            if let surface = token("--color-surface") { layer["style"] = ["fill": surface] }
        case .text:
            layer["name"] = "Text"
            layer["text"] = "Text"
            var style: [String: Any] = [:]
            style["font"] = token("--type-body")
            style["color"] = token("--color-ink")
            layer["style"] = style
        case .rect:
            layer["name"] = "Shape"
            layer["h"] = 120
            layer["style"] = ["fill": token("--color-surface") ?? "#808080", "radius": token("--radius-md") ?? 8] as [String: Any]
        case .image:
            return chooseImageFile()
        case .instance:
            return
        }
        insert(layer, id: id, in: page, label: "Add \(kind.title)")
    }

    private func insert(_ layer: [String: Any], id: String, in page: DesignPage, label: String, with tx: ((String) -> AetherGraph.Transaction?)? = nil) {
        let (into, at) = placeForNew(in: page)
        if apply([.insert(["layers"], layer), .insert(path(into, ["children"]), id, at: at)], label: label, with: tx?(id)) {
            selection = id
        }
    }

    /// An id like `text-3` the page doesn't have yet.
    static func fresh(_ stem: String, in page: DesignPage) -> String {
        let taken = Set(page.layers.map(\.id))
        var n = 1
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    /// ⌫: the chosen layer and everything in it, out of the page, and the
    /// links its pictures follow with it. Not the page's own frame.
    public func removeSelected() {
        guard let page, let id = selection, let layer = page.layer(id), let up = page.parent(of: id),
              let place = up.children.firstIndex(of: id) else { return }
        // The layers list by id, then the frame's list by place; the core
        // checks nothing is left in no frame.
        let gone = page.subtree(id)
        var ops: [DesignOp] = gone.map { .remove(["layers", "#\($0)"]) }
        ops.append(.remove(path(up.id, ["children", String(place)])))
        let links = gone.compactMap { link(for: $0) }
        let tx = links.isEmpty ? nil : documentPath.map { AetherGraph.Transaction(links.map { .remove($0.id) }, origin: .design, label: "Unlink", document: $0) }
        if apply(ops, label: "Remove \(layer.label)", with: tx) { selection = up.id }
    }

    /// The chosen layer one place earlier (`by` -1) or later (1) in its frame.
    public func moveSelected(by step: Int) {
        guard let page, let id = selection, let up = page.parent(of: id), let place = up.children.firstIndex(of: id) else { return }
        let to = place + step
        guard up.children.indices.contains(to) else { return }
        apply([.move(path(up.id, ["children", String(place)]), to: to)], label: "Move \(page.layer(id)?.label ?? id)")
    }

    /// The chosen layer put into a new frame in its place, laid out in a
    /// `direction`; the new frame chosen.
    public func wrapSelected(direction: String = "column") {
        guard let page, let id = selection, let layer = page.layer(id), let up = page.parent(of: id),
              let place = up.children.firstIndex(of: id) else { return }
        let frame = Self.fresh("frame", in: page)
        let new: [String: Any] = ["id": frame, "kind": "frame", "name": "Frame", "w": "hug", "children": [id], "layout": ["direction": direction]]
        let ops: [DesignOp] = [
            .insert(["layers"], new),
            .set(path(up.id, ["children", String(place)]), frame),
        ]
        if apply(ops, label: "Frame \(layer.label)") { selection = frame }
    }

    // MARK: Components

    /// Edit component `id` in the page's place: its option artboards on the
    /// canvas, its layers in the navigator.
    public func editComponent(_ id: String) {
        guard document?.component(id) != nil else { return }
        componentID = id
        variant = nil
        componentBreakpoint = nil
        selection = nil
        fitRequest &+= 1
    }

    /// Back to the page from a component.
    public func closeComponent() {
        guard componentID != nil else { return }
        let was = componentID
        componentID = nil
        variant = nil
        // The instance of it there was, if any, chosen again.
        selection = page?.layers.first { $0.kind == .instance && $0.component == was }?.id
        fitRequest &+= 1
    }

    /// Where component `id` is placed, by page and instance.
    public func uses(of id: String) -> [DesignView.ComponentRow.Use] {
        document?.view.components.first { $0.id == id }?.uses ?? []
    }

    /// Go to an instance: its page, or the component it's inside; it chosen.
    public func show(_ use: DesignView.ComponentRow.Use) {
        if let holder = use.page.split(separator: ":", maxSplits: 1).last.map(String.init), use.page.hasPrefix("component:") {
            editComponent(holder)
        } else {
            componentID = nil
            variant = nil
            if pageID != use.page { pageID = use.page }
        }
        selection = use.layer
    }

    /// Where a use is, in words: its page's name, or the component's.
    public func place(of use: DesignView.ComponentRow.Use) -> String {
        guard let document else { return use.page }
        if use.page.hasPrefix("component:") {
            let id = String(use.page.dropFirst("component:".count))
            return "in \(document.component(id)?.name ?? id)"
        }
        return document.page(use.page)?.name ?? use.page
    }

    /// The chosen frame made a component, an instance of it in its place:
    /// one step. The component is called what the frame is.
    public func makeComponent() {
        guard let document, let pageID, componentID == nil, let id = selection, let layer = page?.layer(id) else { return }
        guard layer.kind == .frame, id != page?.root else {
            notice = "Choose a frame to make a component of it."
            return
        }
        let name = layer.label.prefix(1).uppercased() + layer.label.dropFirst()
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        if slug.first?.isLetter != true { slug = "c-" + slug }
        var componentID = slug
        var n = 2
        while document.component(componentID) != nil {
            componentID = "\(slug)-\(n)"
            n += 1
        }
        let before = document.steps
        if document.makeComponent(from: id, on: pageID, id: componentID, name: name) {
            if document.steps > before { stepped("Make \(name) a Component") }
            selection = id
        } else if let refusal = document.refusal {
            notice = refusal
        }
    }

    /// An instance of component `id` placed as `placeForNew` says, and
    /// chosen: on the page, or inside the component being edited (not
    /// itself; one that would end up inside itself is refused, and said).
    public func place(component id: String) {
        guard id != componentID, let page, let component = document?.component(id) else { return }
        let layer = Self.fresh(id, in: page)
        insert(["id": layer, "kind": "instance", "component": id, "name": component.name, "w": "hug"], id: layer, in: page, label: "Place \(component.name)")
    }

    /// An instance's option of a prop; nil, the component's default.
    public func setProp(_ id: String, _ prop: String, to option: String?) {
        guard let layer = page?.layer(id), layer.props[prop] != option else { return }
        let key = path(id, ["props", prop])
        if let option {
            apply([.set(key, option)], label: "\(prop.prefix(1).uppercased() + prop.dropFirst()) of \(layer.label)")
        } else {
            apply([.remove(key)], label: "\(prop.prefix(1).uppercased() + prop.dropFirst()) of \(layer.label)")
        }
    }

    /// An instance's words for one of its component's text layers; empty,
    /// the component's own.
    public func setWords(_ id: String, for text: String, to words: String) {
        guard let layer = page?.layer(id), (layer.texts[text] ?? "") != words else { return }
        let key = path(id, ["texts", text])
        apply([words.isEmpty ? .remove(key) : .set(key, words)], label: "Words of \(layer.label)")
    }

    /// An instance disabled, or not; the component's look for it.
    public func setDisabled(_ id: String, _ disabled: Bool) {
        setProp(id, "state", to: disabled ? "disabled" : nil)
    }

    /// The component being edited's states: which it has a look for.
    public func setStates(_ states: [String]) {
        guard let component else { return }
        let ordered = DesignComponent.allStates.filter(states.contains)
        apply([.set(["states"], ordered)], label: "States of \(component.name)")
    }

    /// The chosen instance made plain layers again: its component's, as it
    /// picks them. One step.
    public func detachSelected() {
        guard let document, let pageID, componentID == nil, let id = selection, let layer = page?.layer(id), layer.kind == .instance else { return }
        let label = "Detach \(layer.label)"
        let before = document.steps
        if document.detach(id, on: pageID, label: label) {
            if document.steps > before { stepped(label) }
        } else if let refusal = document.refusal {
            notice = refusal
        }
    }

    /// The component being edited renamed.
    public func renameComponent(_ name: String) {
        guard let component, !name.trimmingCharacters(in: .whitespaces).isEmpty, name != component.name else { return }
        apply([.set(["name"], name.trimmingCharacters(in: .whitespaces))], label: "Rename \(component.name)")
    }

    /// The component's props, all of them, as one step: each a name and its
    /// options, the first the default.
    public func setProps(_ props: [(name: String, options: [String])]) {
        guard component != nil else { return }
        let value: [[String: Any]] = props.map { ["name": $0.name, "options": $0.options] }
        apply([.set(["props"], value)], label: "Props of \(component?.name ?? "")")
    }

    // MARK: Pictures

    /// The link an image layer of the page on screen follows, if any.
    public func link(for id: String) -> AssetLink? {
        guard let project, let path = documentPath, let pageID else { return nil }
        return project.link(in: path, slot: Slot.design(page: pageID, layer: id))
    }

    /// The pictures other workspaces make, for placing.
    public var assets: [Asset] { project?.assets.filter { $0.newest != nil } ?? [] }

    /// The file an image following `asset` names, in the design's folder:
    /// one a picture, written over by each version.
    static func imageName(for asset: Asset) -> String {
        let clean = asset.name.map { "/:\\\"'<>?#".contains($0) ? "-" : $0 }
        return "images/\(String(clean).isEmpty ? "Linked" : String(clean)).png"
    }

    /// An image of `asset`, following its newest version: one step, the
    /// layer and its link together.
    public func addImage(from asset: Asset) {
        guard componentID == nil else {
            notice = "A picture that follows an asset goes on a page; a component takes one from a file."
            return
        }
        guard let project, let document, let page else {
            notice = "Open a design to place \(asset.name) in it."
            return
        }
        guard let version = asset.newest else {
            notice = "\(asset.name) has no version yet."
            return
        }
        let src = Self.imageName(for: asset)
        let file = document.file(src)
        let before = writing
        writing = Task { [weak self] in
            await before?.value
            do {
                let data = try await project.pool.data(version.blob)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                self?.notice = "Couldn’t write \(asset.name) into the design: \(error.localizedDescription)"
                return
            }
            guard let self, self.document === document, self.page?.id == page.id, let path = self.documentPath else { return }
            self.pictureRevision &+= 1
            let id = Self.fresh("image", in: page)
            let layer: [String: Any] = ["id": id, "kind": "image", "name": asset.name, "src": src, "text": asset.name]
            self.insert(layer, id: id, in: page, label: "Add \(asset.name)") { id in
                AetherGraph.Transaction([project.linkOp(asset.id, into: path, slot: Slot.design(page: page.id, layer: id), by: .design)],
                                        origin: .design, label: "Link \(asset.name)", document: path)
            }
        }
    }

    /// A picture from a file, copied into the design's `images/`.
    public func addImage(file url: URL) {
        guard let page, let src = copyIn(url) else { return }
        let id = Self.fresh("image", in: page)
        let name = url.deletingPathExtension().lastPathComponent
        insert(["id": id, "kind": "image", "name": name, "src": src, "text": name], id: id, in: page, label: "Add \(name)")
    }

    /// An image layer's picture replaced by a file; whatever it followed,
    /// it follows no longer.
    public func replaceImage(_ id: String, file url: URL) {
        guard let layer = page?.layer(id), let src = copyIn(url) else { return }
        let tx = link(for: id).flatMap { link in documentPath.map { AetherGraph.Transaction([.remove(link.id)], origin: .design, label: "Unlink", document: $0) } }
        apply([.set(path(id, ["src"]), src)], label: "Replace \(layer.label)", with: tx)
    }

    /// `url` copied into the design's `images/` under a name of its own;
    /// its `src`.
    private func copyIn(_ url: URL) -> String? {
        guard let document else { return nil }
        let kind = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp", "gif"].contains(kind) else {
            notice = "\(url.lastPathComponent) isn’t a PNG, JPEG, WebP or GIF."
            return nil
        }
        let stem = url.deletingPathExtension().lastPathComponent.map { "/:\\\"'<>?#".contains($0) ? "-" : $0 }
        var name = "\(String(stem)).\(kind)"
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: document.file("images/\(name)").path),
              !fm.contentsEqual(atPath: document.file("images/\(name)").path, andPath: url.path) {
            name = "\(String(stem))-\(n).\(kind)"
            n += 1
        }
        let file = document.file("images/\(name)")
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { try fm.copyItem(at: url, to: file) }
        } catch {
            notice = "Couldn’t copy \(url.lastPathComponent) into the design: \(error.localizedDescription)"
            return nil
        }
        pictureRevision &+= 1
        return "images/\(name)"
    }

    /// The Open panel for a picture to place, or to put in the chosen
    /// image layer.
    public func chooseImageFile(replacing id: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]
        panel.message = "The picture is copied into the design's images/ folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id { replaceImage(id, file: url) } else { addImage(file: url) }
    }

    /// Keep a version of an image's asset, or follow the newest again.
    public func keep(_ number: Int?, for link: AssetLink) {
        guard let project else { return }
        do { try project.pin(link, to: number) } catch { notice = error.localizedDescription }
        syncImages()
    }

    /// The link taken away: the picture stays, no longer updated.
    public func unlink(_ link: AssetLink) {
        do { try project?.unlink(link) } catch { notice = error.localizedDescription }
    }

    /// A new version: every image following it, in this design or another,
    /// open or not, has its picture written again.
    private func published(_ asset: Asset, _ version: AssetVersion) {
        guard let project else { return }
        for link in project.links(to: asset.id) where link.consumer == .design && link.pinned == nil {
            write(version, of: asset, for: link)
        }
    }

    /// Pictures the history moved past (a version kept, undone) written as
    /// the links now say.
    func syncImages() {
        guard let project, let path = documentPath else { return }
        for link in project.links(in: path) {
            guard let asset = project.asset(link.asset), let version = project.version(for: link), version.number != link.shown else { continue }
            write(version, of: asset, for: link)
        }
    }

    private func write(_ version: AssetVersion, of asset: Asset, for link: AssetLink) {
        guard let project else { return }
        let file = project.url(of: link.document).appending(path: Self.imageName(for: asset))
        let before = writing
        writing = Task { [weak self] in
            await before?.value
            do {
                let data = try await project.pool.data(version.blob)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                self?.pictureRevision &+= 1
                project.took(version.number, for: link)
            } catch {
                self?.notice = "Couldn’t write \(asset.name) v\(version.number) into the design: \(error.localizedDescription)"
            }
        }
    }

    /// A picture's size in pixels, read from its file's header.
    public func imageSize(_ src: String) -> CGSize? {
        guard let document, let source = CGImageSourceCreateWithURL(document.file(src) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: Tokens

    /// A token's value; `coalescing` for a colour well's drag, which is one
    /// step however far it goes.
    public func setToken(_ token: DesignToken, to value: String, coalescing: Bool = false) {
        guard let document else { return }
        let before = document.steps
        document.setToken(token, to: value, coalescing: coalescing)
        if let refusal = document.refusal { notice = refusal }
        if document.steps > before { stepped("Set \(token.name)") }
    }

    // MARK: Undo, save, preview

    /// Undo the design's newest step, its own or a project step made in it.
    public func undo() {
        guard let document else { return }
        if let project, let path = documentPath { project.undo(in: path) { document.undo() } } else { document.undo() }
        syncImages()
    }

    public func redo() {
        guard let document else { return }
        if let project, let path = documentPath { project.redo(in: path) { document.redo() } } else { document.redo() }
        syncImages()
    }

    public var undoLabel: String? {
        guard let project else { return document?.undoLabel }
        return documentPath.flatMap { project.undoLabel(in: $0) }
    }

    public var redoLabel: String? {
        guard let project else { return document?.redoLabel }
        return documentPath.flatMap { project.redoLabel(in: $0) }
    }

    /// ⌘S: every changed file written, and the sync folder's with them.
    public func saveNow() {
        guard let document else { return }
        do {
            let written = try document.save()
            if let project, let path = documentPath { project.documentSaved(path) }
            let synced = writeSync() ?? []
            var said = written.isEmpty ? "" : "Saved \(written.count == 1 ? written[0] : "\(written.count) files")"
            if !synced.isEmpty, let folder = document.syncFolder {
                said += said.isEmpty ? "Wrote" : ", and wrote"
                said += " \(synced.count) file\(synced.count == 1 ? "" : "s") to \(folder.lastPathComponent)"
            }
            notice = said.isEmpty ? nil : said + "."
            noticeIsGood = !said.isEmpty
        } catch {
            notice = "Couldn’t save: \(DesignDocument.describe(error))"
        }
    }

    // MARK: Sync

    /// The folder of HTML and CSS the design is kept in step with.
    public var syncFolder: URL? { document?.syncFolder }

    /// Keep the design in step with `folder` — what it already holds of the
    /// design's read back, its files written now and on every save, and read
    /// back when they're edited — or with nothing. One step, and a step a
    /// file it reads back.
    public func keepInStep(with folder: URL?) {
        guard let document else { return }
        let path = folder.map { Self.path(of: $0, from: document.url) }
        let label = folder.map { "Keep in Step with \($0.lastPathComponent)" } ?? "Stop Keeping in Step"
        let before = document.steps
        if document.setSync(path, label: label), document.steps > before { stepped(label) }
        if let refusal = document.refusal { notice = refusal }
        known = [:]
        syncNotes = []
        // What the folder already holds of the design's comes in first, so
        // choosing it never writes over edits made there.
        checkSync()
        if let written = writeSync(), let folder = document.syncFolder {
            let wrote = written.isEmpty ? "Kept in step with \(folder.lastPathComponent)" : "Wrote \(written.count) file\(written.count == 1 ? "" : "s") to \(folder.lastPathComponent)"
            notice = "\(wrote): edits to its files come back to the design."
            noticeIsGood = true
        }
        watch()
    }

    /// The Open panel for the folder to keep the design in step with.
    public func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep in Step"
        panel.message = "Each component and page is written here as HTML and CSS, and edits to them come back to the design."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keepInStep(with: url)
    }

    /// `folder` as `design.json` says it: from the design's folder when
    /// it's near (`../../src/components`), else whole.
    static func path(of folder: URL, from design: URL) -> String {
        let to = folder.standardizedFileURL.pathComponents
        let from = design.standardizedFileURL.pathComponents
        let shared = zip(to, from).prefix { $0 == $1 }.count
        // Nothing shared but the disk's root: whole.
        guard shared > 1 else { return folder.standardizedFileURL.path }
        return (Array(repeating: "..", count: from.count - shared) + to[shared...]).joined(separator: "/")
    }

    /// The folder's files written as the design is now, and remembered as
    /// what they hold; those written, or nil when there's no folder.
    @discardableResult
    func writeSync() -> [String]? {
        guard let document, let folder = document.syncFolder else { return nil }
        do {
            let written = try document.syncOut()
            for rel in document.syncFiles { known[rel] = try? String(contentsOf: folder.appending(path: rel), encoding: .utf8) }
            return written
        } catch {
            notice = "Couldn’t write to \(folder.lastPathComponent): \(DesignDocument.describe(error))"
            return nil
        }
    }

    /// Each file of the folder that holds something other than what Aether
    /// last wrote or read, read back: a step a file that changes the design.
    public func checkSync() {
        guard let document, let folder = document.syncFolder else { return }
        for rel in document.syncFiles where rel != "theme.css" {
            guard let text = try? String(contentsOf: folder.appending(path: rel), encoding: .utf8), text != known[rel] else { continue }
            known[rel] = text
            guard let read = document.syncIn(rel, text: text) else {
                if let refusal = document.refusal { notice = "\(rel) couldn’t be read back: \(refusal)" }
                continue
            }
            if read.changed { stepped("From \(rel)") }
            if !read.notes.isEmpty {
                syncNotes = read.notes
                notice = read.notes.count == 1 ? read.notes[0] : "\(read.notes[0]) (and \(read.notes.count - 1) more, in the inspector)"
            } else if read.changed {
                syncNotes = []
            }
        }
    }

    /// Look for edits to the folder once a second while the design is open.
    private func watch() {
        watching?.cancel()
        guard document?.syncFolder != nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.checkSync()
            }
        }
    }

    /// The code drawer's contents: the chosen layer's, or the page's.
    public var code: DesignCode? {
        guard let document else { return nil }
        if let componentID { return document.code(component: componentID) }
        guard let page else { return nil }
        return document.code(page: page.id, layer: selection ?? page.root)
    }

    /// Preview (⌘↩): the page as it is now, unsaved edits and all, written
    /// as HTML beside its theme and its pictures in a folder of its own, and
    /// opened in the browser. A browser draws it; Aether has no web view.
    @discardableResult
    public func preview() -> URL? {
        guard let document, let pageID, let page = document.page(pageID) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "Aether Preview/\(document.url.lastPathComponent)", directoryHint: .isDirectory)
        let file = dir.appending(path: "\(page.id).html")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let html = document.html(page: page.id, themeHref: "theme.css") else { return nil }
            try Data(html.utf8).write(to: file, options: .atomic)
            try Data(document.themeText.utf8).write(to: dir.appending(path: "theme.css"), options: .atomic)
            let images = document.file("images")
            let copied = dir.appending(path: "images")
            try? fm.removeItem(at: copied)
            if fm.fileExists(atPath: images.path) { try fm.copyItem(at: images, to: copied) }
        } catch {
            notice = "Couldn’t write the preview: \(error.localizedDescription)"
            return nil
        }
        if !Self.previewsQuietly { NSWorkspace.shared.open(file) }
        return file
    }

    /// Tests write the preview without opening a browser.
    nonisolated(unsafe) static var previewsQuietly = false
}
