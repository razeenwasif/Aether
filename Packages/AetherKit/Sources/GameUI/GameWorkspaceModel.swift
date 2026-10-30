import AppKit
import Foundation
import GameCore
import ImageIO
import Observation

/// The Game workspace's state: the games in the project's `Games/`, the one
/// open, the room on screen, what is selected, and Play.
@MainActor
@Observable
public final class GameWorkspaceModel {
    /// Where games go: the project's `Games/`, a folder a game.
    public private(set) var folder: URL
    public private(set) var games: [GameFound] = []
    public private(set) var document: GameDocument?
    /// The room on screen, by id.
    public var roomID: String? {
        didSet { if roomID != oldValue { selected = nil; fitRequest &+= 1 } }
    }
    /// The entity selected, by id.
    public var selected: String?
    public var navigatorOpen = true
    public var inspectorOpen = true
    public var notice: String? {
        didSet { noticeIsGood = false }
    }
    /// Whether the notice says something went well.
    public private(set) var noticeIsGood = false
    /// The name the home page's form makes a game with.
    public var newName = "Lumen"
    /// Play, while it runs.
    public private(set) var player: GamePlayer?
    /// The player's health and most, for the HUD, as they change.
    public private(set) var health: (now: Int, most: Int) = (0, 0)
    /// Bumped to have the stage show the whole room.
    public private(set) var fitRequest = 0
    @ObservationIgnored public let images = GameImages()

    public init(folder: URL) {
        self.folder = folder
        refreshList()
    }

    public var room: GameRoom? { roomID.flatMap { document?.room($0) } }
    public var playing: Bool { player != nil }

    /// Point at another project's `Games/`, closing the game open.
    public func switchFolder(to folder: URL) {
        stop()
        document = nil
        roomID = nil
        self.folder = folder
        refreshList()
    }

    public func refreshList() {
        games = GameDocument.found(in: folder)
    }

    /// A new game from Proton's template, named on the home page's form,
    /// in a folder of its own, opened.
    public func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return notice = "Name the game first." }
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        var dir = folder.appending(path: slug, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = folder.appending(path: "\(slug)_\(n)", directoryHint: .isDirectory)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try GameDocument.create(named: name, in: dir)
            refreshList()
            open(dir)
        } catch {
            notice = "Couldn’t make \(name): \(GameDocument.describe(error))"
        }
    }

    public func open(_ url: URL) {
        stop()
        do {
            let doc = try GameDocument(url: url)
            document = doc
            images.root = url
            roomID = doc.view.rooms.first?.id
            fitRequest &+= 1
        } catch {
            notice = "Couldn’t open \(url.lastPathComponent): \(GameDocument.describe(error))"
        }
    }

    /// Back to the games: refused while anything is unsaved, which says so.
    public func close() {
        guard let document else { return }
        if !document.unsaved.isEmpty {
            notice = "\(document.name) has unsaved changes: save them (⌘S) first."
            return
        }
        stop()
        self.document = nil
        roomID = nil
        refreshList()
    }

    // MARK: Editing

    private var roomTarget: String? { roomID.map { "room:\($0)" } }

    /// The selected thing moved `dx`, `dy` room pixels, as one step.
    public func moveEntity(_ id: String, by dx: Int, _ dy: Int) {
        guard let target = roomTarget, let entity = room?.entity(id), dx != 0 || dy != 0 else { return }
        var ops: [GameOp] = []
        if let at = entity.at { ops.append(.set(["entities", "#\(id)", "at"], [at[0] + dx, at[1] + dy])) }
        if let r = entity.rect { ops.append(.set(["entities", "#\(id)", "rect"], [r[0] + dx, r[1] + dy, r[2], r[3]])) }
        apply(ops, to: target, label: "Move \(id)")
    }

    /// Where the selected thing stands, set from the inspector.
    public func setPlace(_ id: String, x: Int, y: Int) {
        guard let entity = room?.entity(id) else { return }
        let from = entity.at ?? Array((entity.rect ?? [0, 0]).prefix(2))
        moveEntity(id, by: x - from[0], y - from[1])
    }

    public func removeSelected() {
        guard let target = roomTarget, let id = selected else { return }
        if apply([.remove(["entities", "#\(id)"])], to: target, label: "Remove \(id)") { selected = nil }
    }

    @discardableResult
    private func apply(_ ops: [GameOp], to target: String, label: String) -> Bool {
        guard let document else { return false }
        let changed = document.apply(ops, to: target, label: label)
        if let refusal = document.refusal { notice = refusal }
        return changed
    }

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
            notice = "Couldn’t save: \(GameDocument.describe(error))"
        }
    }

    // MARK: Play

    /// ▶: the game as it is now, unsaved edits and all, from its start, in
    /// the stage. Cooking is native and takes a moment, so there's no load
    /// step; the keys are the game's until Esc.
    public func play() {
        guard let document, player == nil else { return }
        do {
            let next = try GamePlayer(document.run())
            player = next
            keys = GamePlayer.keys(document.view.game.input)
            health = (next.now.health, next.now.mostHealth)
            notice = nil
        } catch {
            notice = "Couldn’t play \(document.name): \(GameDocument.describe(error))"
        }
    }

    public func togglePlay() {
        playing ? stop() : play()
    }

    /// Esc: the run ends, and is replayed on a fresh run of the same world
    /// to check it ends in the same place, as Proton checked its two builds.
    public func stop() {
        guard let player else { return }
        self.player = nil
        if let check = try? player.replayCheck(), check.ticks > 0 {
            notice = check.same
                ? "Played \(check.ticks) ticks; replayed, it ends in the same state (\(String(check.hash, radix: 16)))."
                : "Played \(check.ticks) ticks, but the replay ended elsewhere: the run isn’t deterministic."
            noticeIsGood = check.same
        }
    }

    /// Each key's bits, by Proton's key names, while playing.
    @ObservationIgnored var keys: [String: UInt32] = [:]

    /// A key went down or up, by Proton's name for it.
    func key(_ name: String, down: Bool) {
        guard let player, let bit = keys[name] else { return }
        if down { player.held |= bit } else { player.held &= ~bit }
    }

    /// The HUD's numbers, after the stage stepped the run.
    func ticked() {
        guard let player else { return }
        let next = (player.now.health, player.now.mostHealth)
        if next != health { health = next }
    }
}

/// A game's images, read once each from its folder.
@MainActor
public final class GameImages {
    var root: URL?
    private var cache: [String: CGImage] = [:]
    private var missing: Set<String> = []

    public func image(_ rel: String) -> CGImage? {
        if let hit = cache[rel] { return hit }
        guard !missing.contains(rel), let root else { return nil }
        let url = root.appending(path: rel)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            missing.insert(rel)
            return nil
        }
        cache[rel] = image
        return image
    }
}
