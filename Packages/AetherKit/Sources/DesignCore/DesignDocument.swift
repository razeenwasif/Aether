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
        for row in view.pages { readPage(row.id) }
    }

    public var name: String { view.design.name }
    public var tokens: [DesignToken] { view.theme.tokens }

    public func page(_ id: String) -> DesignPage? { pages[id] }

    /// A batch of ops on page `id` as one step called `label`. Whether it
    /// changed anything.
    @discardableResult
    public func apply(_ ops: [DesignOp], toPage id: String, label: String) -> Bool {
        let target = "page:\(id)"
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
    /// undoes in one.
    @discardableResult
    public func setToken(_ token: DesignToken, to value: String, coalescing: Bool = false) -> Bool {
        let key = token.id
        // Back to before the newest step, then the step again with the new
        // value: one entry from the old value to the newest.
        let merging = coalescing && done.last?.token == key && undone.isEmpty && (try? editor.undo(targetName: "theme")) == true
        if merging { done.removeLast() }
        defer { reload("theme") }
        do {
            let changed = try editor.setToken(name: token.name, scope: token.scope, value: value)
            refusal = nil
            // Dragged back to where it started, there is no step left.
            if changed {
                done.append(Step(target: "theme", label: "Set \(token.name)", token: key))
                undone.removeAll()
            }
            return changed
        } catch {
            refusal = Self.describe(error)
            if merging, (try? editor.redo(targetName: "theme")) == true {
                done.append(Step(target: "theme", label: "Set \(token.name)", token: key))
            }
            return false
        }
    }

    /// The next step back's name and the next step on's.
    public var undoLabel: String? { done.last?.label }
    public var redoLabel: String? { undone.last?.label }

    public func undo() {
        guard let last = done.popLast() else { return }
        if (try? editor.undo(targetName: last.target)) == true { undone.append(last) }
        reload(last.target)
    }

    public func redo() {
        guard let next = undone.popLast() else { return }
        if (try? editor.redo(targetName: next.target)) == true { done.append(next) }
        reload(next.target)
    }

    /// Write every changed file; the files written.
    @discardableResult
    public func save() throws -> [String] {
        let written = try editor.save()
        reload(nil)
        return written
    }

    /// The files changed and not saved.
    public var unsaved: [String] { view.unsaved }

    /// Page `id` as an HTML document whose tokens come from `themeHref`.
    public func html(page id: String, themeHref: String) -> String? {
        editor.html(id: id, themeHref: themeHref)
    }

    /// The theme's text as it is now, saved or not.
    public var themeText: String { editor.themeText() }

    /// A layer's elements and rules.
    public func code(page id: String, layer: String) -> DesignCode? {
        editor.code(id: id, layer: layer).flatMap { try? Self.decode(DesignCode.self, $0) }
    }

    /// The core's state read again: the view, and the page `target` names.
    private func reload(_ target: String?) {
        if let fresh = try? Self.decode(DesignView.self, editor.view()) { view = fresh }
        if let target, target.hasPrefix("page:") {
            readPage(String(target.dropFirst(5)))
        } else if target == nil {
            for row in view.pages { readPage(row.id) }
        }
        revision &+= 1
    }

    private func readPage(_ id: String) {
        guard let text = editor.page(id: id), let page = try? Self.decode(DesignPage.self, text) else { return }
        pages[id] = page
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
