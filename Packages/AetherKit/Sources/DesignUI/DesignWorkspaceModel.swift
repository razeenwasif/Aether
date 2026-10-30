import AppKit
import DesignCore
import Foundation
import Observation

/// Which list the navigator shows.
public enum DesignNavigatorTab: String, CaseIterable, Sendable {
    case layers = "Layers"
    case tokens = "Tokens"
}

/// The Design workspace's state: the designs in the project's `Designs/`,
/// the one open, the page on screen, the layer chosen, and the panels.
@MainActor
@Observable
public final class DesignWorkspaceModel {
    /// Where designs go: the project's `Designs/`, a folder a design.
    public private(set) var folder: URL
    public private(set) var designs: [DesignFound] = []
    public private(set) var document: DesignDocument?
    /// The page on screen, by id.
    public var pageID: String? {
        didSet { if pageID != oldValue { selection = nil; fitRequest &+= 1 } }
    }
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

    public init(folder: URL) {
        self.folder = folder
        refreshList()
    }

    public var page: DesignPage? { pageID.flatMap { document?.page($0) } }
    public var chosen: DesignLayer? { selection.flatMap { page?.layer($0) } }
    public var resolver: DesignResolver { DesignResolver(tokens: document?.tokens ?? []) }

    /// Point at another project's `Designs/`, closing the design open.
    public func switchFolder(to folder: URL) {
        document = nil
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
            document = doc
            pageID = doc.view.pages.first?.id
            selection = nil
            fitRequest &+= 1
            if let problem = doc.view.problems.first { notice = problem }
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
        self.document = nil
        pageID = nil
        refreshList()
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

    private func apply(_ ops: [DesignOp], label: String) -> Bool {
        guard let document, let pageID else { return false }
        let changed = document.apply(ops, toPage: pageID, label: label)
        if let refusal = document.refusal { notice = refusal }
        return changed
    }

    private func path(_ id: String, _ keys: String...) -> [String] {
        ["layers", "#\(id)"] + keys
    }

    public func rename(_ id: String, to name: String) {
        guard let layer = page?.layer(id) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        _ = apply([.set(path(id, "name"), name.isEmpty || name == id ? nil : name)], label: "Rename \(layer.label)")
    }

    public func setText(_ id: String, _ text: String) {
        guard let layer = page?.layer(id), layer.text != text else { return }
        _ = apply([.set(path(id, "text"), text)], label: "Edit \(layer.label)")
    }

    /// A width or height: `hug`, `fill`, points, or nil for the kind's own.
    public func setSize(_ id: String, width: Bool, to value: DesignVal?) {
        guard let layer = page?.layer(id) else { return }
        _ = apply([.set(path(id, width ? "w" : "h"), value?.json)], label: "\(width ? "Width" : "Height") of \(layer.label)")
    }

    public func setNarrowest(_ id: String, to points: Double?) {
        guard let layer = page?.layer(id) else { return }
        _ = apply([.set(path(id, "minW"), points)], label: "Narrowest of \(layer.label)")
    }

    /// One of a frame's layout fields (`direction`, `gap`, `padH`, `padV`,
    /// `align`, `justify`, `wrap`), or nil to say nothing.
    public func setLayout(_ id: String, _ key: String, to value: Any?) {
        guard let layer = page?.layer(id) else { return }
        _ = apply([.set(path(id, "layout", key), value)], label: "\(Self.title(key)) of \(layer.label)")
    }

    /// One of a layer's style fields (`fill`, `stroke`, `radius`, `color`,
    /// `font`, `textAlign`, `opacity`), or nil to say nothing.
    public func setStyle(_ id: String, _ key: String, to value: Any?) {
        guard let layer = page?.layer(id) else { return }
        _ = apply([.set(path(id, "style", key), value)], label: "\(Self.title(key)) of \(layer.label)")
    }

    static func title(_ key: String) -> String {
        switch key {
        case "padH": "Padding"
        case "padV": "Padding"
        case "textAlign": "Alignment"
        case "minW": "Narrowest"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// A new layer of `kind`: inside the chosen frame at its end, or after
    /// the chosen layer in its frame, or at the end of the page. Chosen.
    public func add(_ kind: DesignKind) {
        guard let page else { return }
        let into: String
        var at: Int?
        if let chosen, chosen.kind == .frame {
            into = chosen.id
        } else if let id = selection, let up = page.parent(of: id) {
            into = up.id
            at = (up.children.firstIndex(of: id) ?? up.children.count - 1) + 1
        } else {
            into = page.root
        }
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
        }
        if apply([.insert(["layers"], layer), .insert(path(into, "children"), id, at: at)], label: "Add \(kind.title)") {
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

    /// ⌫: the chosen layer and everything in it, out of the page. Not the
    /// page's own frame.
    public func removeSelected() {
        guard let page, let id = selection, let layer = page.layer(id), let up = page.parent(of: id),
              let place = up.children.firstIndex(of: id) else { return }
        // The layers list by id, then the frame's list by place; the core
        // checks nothing is left in no frame.
        var ops: [DesignOp] = page.subtree(id).map { .remove(["layers", "#\($0)"]) }
        ops.append(.remove(path(up.id, "children", String(place))))
        if apply(ops, label: "Remove \(layer.label)") { selection = up.id }
    }

    /// The chosen layer one place earlier (`by` -1) or later (1) in its frame.
    public func moveSelected(by step: Int) {
        guard let page, let id = selection, let up = page.parent(of: id), let place = up.children.firstIndex(of: id) else { return }
        let to = place + step
        guard up.children.indices.contains(to) else { return }
        _ = apply([.move(path(up.id, "children", String(place)), to: to)], label: "Move \(page.layer(id)?.label ?? id)")
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
            .set(path(up.id, "children", String(place)), frame),
        ]
        if apply(ops, label: "Frame \(layer.label)") { selection = frame }
    }

    // MARK: Tokens

    /// A token's value; `coalescing` for a colour well's drag, which is one
    /// step however far it goes.
    public func setToken(_ token: DesignToken, to value: String, coalescing: Bool = false) {
        guard let document else { return }
        document.setToken(token, to: value, coalescing: coalescing)
        if let refusal = document.refusal { notice = refusal }
    }

    // MARK: Undo, save, preview

    public func undo() { document?.undo() }
    public func redo() { document?.redo() }
    public var undoLabel: String? { document?.undoLabel }
    public var redoLabel: String? { document?.redoLabel }

    /// ⌘S: every changed file written.
    public func saveNow() {
        guard let document else { return }
        do {
            let written = try document.save()
            notice = written.isEmpty ? nil : "Saved \(written.count == 1 ? written[0] : "\(written.count) files")."
            noticeIsGood = !written.isEmpty
        } catch {
            notice = "Couldn’t save: \(DesignDocument.describe(error))"
        }
    }

    /// The code drawer's contents: the chosen layer's, or the page's.
    public var code: DesignCode? {
        guard let document, let page else { return nil }
        return document.code(page: page.id, layer: selection ?? page.root)
    }

    /// Preview (⌘↩): the page as it is now, unsaved edits and all, written
    /// as HTML beside its theme in a folder of its own, and opened in the
    /// browser. A browser draws it; Aether has no web view.
    @discardableResult
    public func preview() -> URL? {
        guard let document, let page else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Aether Preview/\(document.url.lastPathComponent)", directoryHint: .isDirectory)
        let file = dir.appending(path: "\(page.id).html")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let html = document.html(page: page.id, themeHref: "theme.css") else { return nil }
            try Data(html.utf8).write(to: file, options: .atomic)
            try Data(document.themeText.utf8).write(to: dir.appending(path: "theme.css"), options: .atomic)
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
