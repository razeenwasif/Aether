import DiffuseBridge
import Foundation
import Observation

/// One change to a page, at a path through it: a layer is addressed by
/// `#id`, so an edit lands on the layer it was for wherever it sits
/// (proton-game's `Op`, which aether-design's pages take).
public enum DesignOp {
    case set([String], Any?)
    case insert([String], Any, at: Int? = nil)
    case remove([String])
    case move([String], to: Int)

    var json: [String: Any] {
        switch self {
        case let .set(path, value): ["op": "set", "path": path, "value": value ?? NSNull()]
        case let .insert(path, value, at): at.map { ["op": "insert", "path": path, "value": value, "at": $0] } ?? ["op": "insert", "path": path, "value": value]
        case let .remove(path): ["op": "remove", "path": path]
        case let .move(path, to): ["op": "move", "path": path, "to": to]
        }
    }
}

/// A design open for editing: its pages, changed by ops the core applies
/// whole or not at all, and its theme's tokens, spliced into `theme.css`;
/// each document with its own undo, all held until saved. ⌘Z undoes the
/// newest step wherever it was made, a page's or the theme's.
@MainActor
@Observable
public final class DesignDocument {
    public let url: URL
    @ObservationIgnored let editor: DesignEditor
    public private(set) var view: DesignView
    /// Each page as it is now, by id.
    public private(set) var pages: [String: DesignPage] = [:]
    /// Each page with its instances expanded into their components' layers,
    /// as it's drawn.
    public private(set) var expanded: [String: DesignPage] = [:]
    /// Each component as it is now, by id.
    public private(set) var components: [String: DesignComponent] = [:]
    /// Bumped on every change, so a view knows to draw again.
    public private(set) var revision = 0
    /// Why the last edit was refused, in the core's words.
    public private(set) var refusal: String?
    /// The steps made, oldest first: the document each changed, its name,
    /// and for a token the token, so a colour dragged through many values is
    /// one step.
    private var done: [Step] = []
    private var undone: [Step] = []

    private struct Step {
        var target: String
        var label: String
        var token: String?
    }

    public init(url: URL) throws {
        self.url = url
        editor = try DesignEditor.open(path: url.path)
        view = try Self.decode(DesignView.self, editor.view())
        readAll()
    }

    public var name: String { view.design.name }
    public var tokens: [DesignToken] { view.theme.tokens }

    public func page(_ id: String) -> DesignPage? { pages[id] }

    public func component(_ id: String) -> DesignComponent? { components[id] }

    /// A batch of ops on page `id` as one step called `label`. Whether it
    /// changed anything.
    @discardableResult
    public func apply(_ ops: [DesignOp], toPage id: String, label: String) -> Bool {
        apply(ops, target: "page:\(id)", label: label)
    }

    /// A batch of ops on component `id` as one step: every page that places
    /// it changes with it.
    @discardableResult
    public func apply(_ ops: [DesignOp], toComponent id: String, label: String) -> Bool {
        apply(ops, target: "component:\(id)", label: label)
    }

    /// Component `id` made from frame `layer` of page `page`, an instance in
    /// its place: one step.
    @discardableResult
    public func makeComponent(from layer: String, on page: String, id: String, name: String) -> Bool {
        do {
            try editor.makeComponent(page: page, layer: layer, id: id, name: name)
            refusal = nil
            done.append(Step(target: "made:\(id)/\(page)", label: "Make \(name) a Component"))
            undone.removeAll()
            reload(nil)
            return true
        } catch {
            refusal = Self.describe(error)
            return false
        }
    }

    // MARK: Sync

    /// The folder of HTML and CSS the design is kept in step with: as
    /// `design.json` says it, from the design's folder or whole (as the
    /// core reads it), and observed with the view.
    public var syncFolder: URL? {
        let said = view.design.sync.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return nil }
        let url = said.hasPrefix("/") ? URL(fileURLWithPath: said, isDirectory: true) : url.appending(path: said, directoryHint: .isDirectory)
        return url.standardizedFileURL
    }

    /// The files that folder holds, by where they are in it.
    public var syncFiles: [String] { editor.syncFiles() }

    /// Keep the design in step with `path` (from the design's folder, or
    /// whole), or with nothing: one step of `design.json`.
    @discardableResult
    public func setSync(_ path: String?, label: String) -> Bool {
        apply([.set(["sync"], path ?? "")], target: "design", label: label)
    }

    /// Write the folder's files as the design is now; those written.
    public func syncOut() throws -> [String] {
        try editor.syncOut()
    }

    /// A file of the folder, as `text`, read back: one step, called
    /// `From <file>`, when it changes anything.
    public func syncIn(_ rel: String, text: String) -> DesignSyncRead? {
        do {
            let read = try Self.decode(DesignSyncRead.self, editor.syncIn(rel: rel, text: text))
            refusal = nil
            if read.changed {
                done.append(Step(target: read.target, label: "From \(rel)"))
                undone.removeAll()
                reload(read.target)
            }
            return read
        } catch {
            refusal = Self.describe(error)
            return nil
        }
    }

    /// Instance `layer` of page `page` made plain layers again: one step of
    /// the page.
    @discardableResult
    public func detach(_ layer: String, on page: String, label: String) -> Bool {
        do {
            try editor.detach(page: page, layer: layer)
            refusal = nil
            done.append(Step(target: "page:\(page)", label: label))
            undone.removeAll()
            reload("page:\(page)")
            return true
        } catch {
            refusal = Self.describe(error)
            return false
        }
    }

    private func apply(_ ops: [DesignOp], target: String, label: String) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: ops.map(\.json))
            let changed = try editor.apply(targetName: target, ops: String(decoding: data, as: UTF8.self))
            refusal = nil
            guard changed else { return false }
            done.append(Step(target: target, label: label))
            undone.removeAll()
            reload(target)
            return true
        } catch {
            refusal = Self.describe(error)
            return false
        }
    }

    /// A token's value, as one step. `coalescing`: a change to the same
    /// token as the newest step replaces that step's value rather than
    /// adding another, so a colour well dragged through a hundred colours
    /// undoes in one. Whether it changed the theme; `steps` says whether a
    /// step was added.
    @discardableResult
    public func setToken(_ token: DesignToken, to value: String, coalescing: Bool = false) -> Bool {
        let key = token.id
        defer { reload("theme") }
        // Back to before the newest step, then the step again with the new
        // value: one entry from the old value to the newest.
        let merging = coalescing && done.last?.token == key && undone.isEmpty && (try? editor.undo(targetName: "theme")) == true
        do {
            if try editor.setToken(name: token.name, scope: token.scope, value: value) {
                refusal = nil
                if !merging {
                    done.append(Step(target: "theme", label: "Set \(token.name)", token: key))
                    undone.removeAll()
                }
                return true
            }
            refusal = nil
            guard merging else { return false }
            // Dragged back to where it began: the drag's step put back, and
            // this a step of its own, so each entry is still one step.
            _ = try editor.redo(targetName: "theme")
            guard try editor.setToken(name: token.name, scope: token.scope, value: value) else { return false }
            done.append(Step(target: "theme", label: "Set \(token.name)", token: key))
            return true
        } catch {
            refusal = Self.describe(error)
            if merging { _ = try? editor.redo(targetName: "theme") }
            return false
        }
    }

    /// How many steps there are to undo: grown by one when an edit made a
    /// step, the same when it was merged into the last.
    public var steps: Int { done.count }

    /// The next step back's name and the next step on's.
    public var undoLabel: String? { done.last?.label }
    public var redoLabel: String? { undone.last?.label }

    /// Undo the newest step; whether there was one.
    @discardableResult
    public func undo() -> Bool {
        guard let last = done.popLast() else { return false }
        let did = (try? editor.undo(targetName: last.target)) == true
        if did { undone.append(last) }
        reload(last.target)
        return did
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = undone.popLast() else { return false }
        let did = (try? editor.redo(targetName: next.target)) == true
        if did { done.append(next) }
        reload(next.target)
        return did
    }

    /// The design's folder: where `src` is.
    public func file(_ src: String) -> URL { url.appending(path: src) }

    /// Write every changed file; the files written.
    @discardableResult
    public func save() throws -> [String] {
        let written = try editor.save()
        reload(nil)
        return written
    }

    /// The files changed and not saved.
    public var unsaved: [String] { view.unsaved }

    /// Page `id` as an HTML document whose tokens come from `themeHref`,
    /// its pictures' `images/` under `base`.
    public func html(page id: String, themeHref: String, base: String = "") -> String? {
        editor.html(id: id, themeHref: themeHref, base: base)
    }

    /// The theme's text as it is now, saved or not.
    public var themeText: String { editor.themeText() }

    /// A layer's elements and rules.
    public func code(page id: String, layer: String) -> DesignCode? {
        editor.code(id: id, layer: layer).flatMap { try? Self.decode(DesignCode.self, $0) }
    }

    /// A component as its instances are written.
    public func code(component id: String) -> DesignCode? {
        editor.componentCode(id: id).flatMap { try? Self.decode(DesignCode.self, $0) }
    }

    /// The core's state read again: the view, and what `target` changed —
    /// a page; or with a component, every page that might place it.
    private func reload(_ target: String?) {
        if let fresh = try? Self.decode(DesignView.self, editor.view()) { view = fresh }
        if let target, target.hasPrefix("page:") {
            readPage(String(target.dropFirst(5)))
        } else if target != "theme" {
            readAll()
        }
        revision &+= 1
    }

    private func readAll() {
        components = [:]
        for row in view.components {
            if let text = editor.component(id: row.id), let c = try? Self.decode(DesignComponent.self, text) { components[row.id] = c }
        }
        for row in view.pages { readPage(row.id) }
    }

    private func readPage(_ id: String) {
        guard let text = editor.page(id: id), let page = try? Self.decode(DesignPage.self, text) else { return }
        pages[id] = page
        expanded[id] = editor.expanded(id: id).flatMap { try? Self.decode(DesignPage.self, $0) } ?? page
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? DiffuseError {
            switch e {
            case .Failed(let message), .Gateway(_, let message): return message
            }
        }
        return error.localizedDescription
    }

    /// The designs in `folder`, by name.
    public nonisolated static func found(in folder: URL) -> [DesignFound] {
        (try? JSONDecoder().decode([DesignFound].self, from: Data(designFound(folder: folder.path).utf8))) ?? []
    }

    /// A new design called `name` in `folder`, from the starter.
    public nonisolated static func create(named name: String, in folder: URL) throws {
        try designCreate(dir: folder.path, name: name)
    }
}
