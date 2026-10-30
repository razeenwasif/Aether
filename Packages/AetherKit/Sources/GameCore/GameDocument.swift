import DiffuseBridge
import Foundation
import Observation

/// One change to a game's document, at a path through it: a list's member
/// is addressed by `#id`, so an edit lands on the thing it was for even if
/// the list moved under it (proton-game's `Op`).
public enum GameOp {
    case set([String], Any)
    case insert([String], Any, at: Int? = nil)
    case remove([String])
    case move([String], to: Int)

    var json: [String: Any] {
        switch self {
        case let .set(path, value): ["op": "set", "path": path, "value": value]
        case let .insert(path, value, at): at.map { ["op": "insert", "path": path, "value": value, "at": $0] } ?? ["op": "insert", "path": path, "value": value]
        case let .remove(path): ["op": "remove", "path": path]
        case let .move(path, to): ["op": "move", "path": path, "to": to]
        }
    }
}

/// What bringing art in did: a room's planes changed, or an animation (or a
/// skeleton) made, in words, with what was left out or changed.
public struct GameImported: Decodable, Sendable {
    /// `room`, `anim` or `skel`.
    public var kind: String
    public var room: String?
    /// The animation or skeleton made.
    public var path: String?
    public var said: String
    public var notes: [String]
}

/// A game open for editing: its folder's documents, changed by ops the core
/// applies whole or not at all, each document with its own undo, and held
/// until saved. ⌘Z undoes the newest edit wherever it was made, as Proton's
/// Game did.
@MainActor
@Observable
public final class GameDocument {
    public let url: URL
    @ObservationIgnored let editor: GameEditor
    public private(set) var view: GameProjectView
    /// Each room as it is now, by id.
    public private(set) var rooms: [String: GameRoom] = [:]
    /// Bumped on every change, so a view knows to draw again.
    public private(set) var revision = 0
    /// Why the last edit was refused, in the core's words.
    public private(set) var refusal: String?
    /// The documents edited, oldest first, with each edit's name: what ⌘Z
    /// and ⇧⌘Z walk. Observed, so the Edit menu's names keep up.
    private var done: [(target: String, label: String)] = []
    private var undone: [(target: String, label: String)] = []

    public init(url: URL) throws {
        self.url = url
        editor = try GameEditor.open(path: url.path)
        view = try Self.decode(GameProjectView.self, editor.view())
        for row in view.rooms { readRoom(row.id) }
    }

    public var name: String { view.game.name }

    public func room(_ id: String) -> GameRoom? { rooms[id] }

    /// A batch of ops on `target` (`room:<id>`, `prefab:<id>`, `game`,
    /// `world`) as one step called `label`. Whether it changed anything.
    @discardableResult
    public func apply(_ ops: [GameOp], to target: String, label: String) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: ops.map(\.json))
            let changed = try editor.apply(targetName: target, ops: String(decoding: data, as: UTF8.self))
            refusal = nil
            guard changed else { return false }
            done.append((target, label))
            undone.removeAll()
            reload(target)
            return true
        } catch {
            refusal = Self.describe(error)
            return false
        }
    }

    /// The next step back's name and the next step on's, as the Edit menu
    /// puts them after "Undo" and "Redo".
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

    /// Write every changed document; the files written.
    @discardableResult
    public func save() throws -> [String] {
        let written = try editor.save()
        reload(nil)
        return written
    }

    /// The files changed and not saved.
    public var unsaved: [String] { view.unsaved }

    /// Art brought in from `source`, a file in the game's folder: a `.psd` or
    /// `.png` made into planes of `room` (or the room it went into last
    /// time) at `scale` room pixels a source pixel (0: as last time), with
    /// normal maps if `normals`; an Aseprite file or a sheet's JSON made into
    /// an animation. The images are written at once; a room's planes change
    /// as one step, held until saved.
    public func importArt(_ source: String, room: String, scale: Double = 0, normals: Bool = true) throws -> GameImported {
        let text = try editor.importArt(source: source, room: room, scale: scale, normals: normals)
        let done = try Self.decode(GameImported.self, text)
        if done.kind == "room", let id = done.room,
           let planes = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["planes"] {
            let file = source.split(separator: "/").last.map(String.init) ?? source
            if !apply([.set(["planes"], planes)], to: "room:\(id)", label: "Import \(file)"), let refusal {
                throw DiffuseError.Failed(message: refusal)
            }
        } else {
            reload(nil)
        }
        return done
    }

    /// A run of the game as it is now, unsaved edits and all.
    public func run() throws -> GameRun {
        try editor.run()
    }

    /// The core's state read again: the view, and the room `target` names.
    private func reload(_ target: String?) {
        if let fresh = try? Self.decode(GameProjectView.self, editor.view()) { view = fresh }
        if let target, target.hasPrefix("room:") {
            readRoom(String(target.dropFirst(5)))
        } else if target == nil || target == "world" {
            for row in view.rooms { readRoom(row.id) }
        }
        revision &+= 1
    }

    private func readRoom(_ id: String) {
        guard let text = editor.room(id: id), let room = try? Self.decode(GameRoom.self, text) else { return }
        rooms[id] = room
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

    /// The games in `folder`, by name.
    public nonisolated static func found(in folder: URL) -> [GameFound] {
        (try? JSONDecoder().decode([GameFound].self, from: Data(gameFound(folder: folder.path).utf8))) ?? []
    }

    /// A new game called `name` in `folder`, from Proton's template.
    public nonisolated static func create(named name: String, in folder: URL) throws {
        try gameCreate(dir: folder.path, name: name)
    }
}
