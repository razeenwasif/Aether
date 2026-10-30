import AppKit
import Foundation
import GameCore
import ImageIO
import Observation

/// What's chosen in the room on screen.
public enum GameSelection: Equatable, Sendable {
    case entity(String)
    case shape(String)
    case light(String)
    case spawn(String)

    public var id: String {
        switch self {
        case let .entity(id), let .shape(id), let .light(id), let .spawn(id): id
        }
    }
}

/// What a click on the stage does.
public enum GameTool: Equatable, Sendable {
    /// Choose and move (v).
    case select
    /// Draw a line of collision, a click a point (p).
    case draw
    /// Place a light (l).
    case light
    /// Place a thing: a prefab of the game's, or a built-in kind.
    case place(String)
}

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
        didSet { if roomID != oldValue { selection = nil; tool = .select; fitRequest &+= 1 } }
    }
    /// What's chosen.
    public var selection: GameSelection?
    /// The thing chosen, by id, when a thing is.
    public var selected: String? {
        get { if case let .entity(id) = selection { id } else { nil } }
        set { selection = newValue.map(GameSelection.entity) }
    }
    public var tool: GameTool = .select
    /// The kind of line the draw tool makes: `solid`, `oneway`, `hazard`
    /// or `nowall`.
    public var drawKind = "solid"
    public var navigatorOpen = true
    public var inspectorOpen = true
    /// Whether the editor shows the game's finish (bloom, grade, vignette)
    /// as Play does; ⇧P. Lights fall on lit planes either way.
    public var finishInEditor = false
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

    /// The tool keys, while the stage has the keys and no run is playing.
    func toolKey(_ character: String) -> Bool {
        switch character {
        case "v": tool = .select
        case "p": tool = .draw
        case "l": tool = .light
        case "P": finishInEditor.toggle()
        default: return false
        }
        return true
    }

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

    /// ⌫: what's chosen, taken out of the room.
    public func removeSelected() {
        guard let target = roomTarget, let selection else { return }
        let list = switch selection {
        case .entity: "entities"
        case .shape: "collision"
        case .light: "lights"
        case .spawn: "spawns"
        }
        if apply([.remove([list, "#\(selection.id)"])], to: target, label: "Remove \(selection.id)") { self.selection = nil }
    }

    // MARK: Collision

    /// A line of collision through `points`, of the draw tool's kind, as one
    /// step; it's chosen.
    public func addLine(_ points: [CGPoint]) {
        guard let target = roomTarget, let room, points.count >= 2 else { return }
        let id = room.freshID(drawKind)
        let value: [String: Any] = ["id": id, "kind": drawKind, "points": points.map { [Int($0.x.rounded()), Int($0.y.rounded())] }]
        if apply([.insert(["collision"], value)], to: target, label: "Draw \(id)") { selection = .shape(id) }
    }

    /// Point `index` of a line, moved to `to`.
    public func movePoint(_ shape: String, _ index: Int, to p: CGPoint) {
        guard let target = roomTarget else { return }
        apply([.set(["collision", "#\(shape)", "points", String(index)], [Int(p.x.rounded()), Int(p.y.rounded())])], to: target, label: "Move a point of \(shape)")
    }

    /// A point put into a line, before point `index`.
    public func insertPoint(_ shape: String, at index: Int, _ p: CGPoint) {
        guard let target = roomTarget else { return }
        apply([.insert(["collision", "#\(shape)", "points"], [Int(p.x.rounded()), Int(p.y.rounded())], at: index)], to: target, label: "Add a point to \(shape)")
    }

    /// Point `index` taken out of a line that keeps two at least.
    public func removePoint(_ shape: String, _ index: Int) {
        guard let target = roomTarget, let line = room?.shape(shape) else { return }
        guard line.points.count > 2 else { return notice = "A line needs two points at least: remove the line instead (⌫)." }
        apply([.remove(["collision", "#\(shape)", "points", String(index)])], to: target, label: "Remove a point of \(shape)")
    }

    /// The whole line moved `dx`, `dy`.
    public func moveLine(_ shape: String, by dx: Int, _ dy: Int) {
        guard let target = roomTarget, let line = room?.shape(shape), dx != 0 || dy != 0 else { return }
        apply([.set(["collision", "#\(shape)", "points"], line.points.map { [$0[0] + dx, $0[1] + dy] })], to: target, label: "Move \(shape)")
    }

    public func setLineKind(_ shape: String, _ kind: String) {
        guard let target = roomTarget else { return }
        apply([.set(["collision", "#\(shape)", "kind"], kind)], to: target, label: "Make \(shape) \(kind)")
    }

    public func setLineClosed(_ shape: String, _ closed: Bool) {
        guard let target = roomTarget else { return }
        apply([.set(["collision", "#\(shape)", "closed"], closed)], to: target, label: closed ? "Close \(shape)" : "Open \(shape)")
    }

    // MARK: Lights, spawns and things placed

    /// A light at `p` on the play plane, with Proton's defaults; it's chosen.
    public func addLight(at p: CGPoint) {
        guard let target = roomTarget, let room else { return }
        guard let plane = room.playPlane?.id ?? room.planes.last?.id else { return notice = "This room has no plane to stand a light on." }
        let id = room.freshID("light")
        let value: [String: Any] = ["id": id, "plane": plane, "at": [Int(p.x.rounded()), Int(p.y.rounded())], "radius": 400, "color": "#ffd9a0", "intensity": 1, "glow": 0.4]
        if apply([.insert(["lights"], value)], to: target, label: "Add \(id)") { selection = .light(id) }
    }

    public func moveLight(_ id: String, by dx: Int, _ dy: Int) {
        guard let target = roomTarget, let light = room?.light(id), dx != 0 || dy != 0 else { return }
        apply([.set(["lights", "#\(id)", "at"], [light.at[0] + dx, light.at[1] + dy])], to: target, label: "Move \(id)")
    }

    /// One of a light's numbers or its colour, from the inspector.
    public func setLight(_ id: String, _ key: String, _ value: Any) {
        guard let target = roomTarget else { return }
        apply([.set(["lights", "#\(id)", key], value)], to: target, label: "Change \(id)'s \(key)")
    }

    public func moveSpawn(_ id: String, by dx: Int, _ dy: Int) {
        guard let target = roomTarget, let spawn = room?.spawn(id), dx != 0 || dy != 0 else { return }
        apply([.set(["spawns", "#\(id)", "at"], [spawn.at[0] + dx, spawn.at[1] + dy])], to: target, label: "Move spawn \(id)")
    }

    /// What can be placed: the game's prefabs (not the player), then the
    /// kinds every game has.
    public var placeable: [(id: String, name: String)] {
        let prefabs = (document?.view.prefabs ?? []).filter { $0.id != "player" }.map { ($0.id, $0.name.isEmpty ? $0.id : $0.name) }
        let builtIn: [(String, String)] = [("save_point", "Bench"), ("ability_pickup", "Ability"), ("transition", "Door"), ("ability_gate", "Gate"), ("trigger", "Trigger")]
        return prefabs + builtIn
    }

    /// A thing of kind `prefab` placed at `p`: standing there, or covering
    /// an area there for the kinds that cover one. It's chosen.
    public func place(_ prefab: String, at p: CGPoint) {
        guard let target = roomTarget, let room else { return }
        let id = room.freshID(prefab)
        let (x, y) = (Int(p.x.rounded()), Int(p.y.rounded()))
        var value: [String: Any] = ["id": id, "prefab": prefab]
        switch prefab {
        case "transition", "ability_gate", "trigger": value["rect"] = [x - 30, y - 200, 60, 200]
        default: value["at"] = [x, y]
        }
        if prefab == "ability_pickup" { value["grants"] = document?.view.game.abilities.first ?? "dash" }
        if apply([.insert(["entities"], value)], to: target, label: "Place \(id)") { selection = .entity(id) }
    }

    // MARK: Art brought in

    /// The kinds of file a game takes in.
    public static let importable = ["psd", "png", "aseprite", "ase", "json"]
    /// Room pixels a source pixel, for a painter's file brought in.
    public var importScale = 1.0
    /// Whether a painter's file brings normal maps for lights to shade.
    public var importNormals = true

    /// Files brought into the game: a painter's `.psd` or a `.png` into the
    /// room on screen as planes, an Aseprite file or a sprite sheet's JSON as
    /// an animation. A file from outside the game's folder is copied into
    /// its `art/source/` first, with what a sheet's JSON names beside it,
    /// so the game keeps what it was made from.
    public func importFiles(_ urls: [URL]) {
        guard let document else { return notice = "Open a game first, then bring art into it." }
        var said: [String] = []
        var notes: [String] = []
        var failed = false
        for url in urls {
            do {
                let rel = try Self.intoGame(url, root: document.url)
                let done = try document.importArt(rel, room: roomID ?? "", scale: importScale, normals: importNormals)
                said.append(done.said)
                notes += done.notes
                if done.kind == "room", let room = done.room, room != roomID { roomID = room }
            } catch {
                failed = true
                said.append("Couldn’t bring in \(url.lastPathComponent): \(GameDocument.describe(error))")
            }
        }
        images.forget()
        let words = said.joined(separator: " ") + (notes.isEmpty ? "" : " Notes: " + notes.joined(separator: "; ") + ".")
        notice = words
        noticeIsGood = !failed
    }

    /// A file's place in the game's folder: where it is, if it's inside;
    /// else copied in. A painter's file goes into `art/source/` (its layers
    /// are written to a folder of their own); an animation's source into a
    /// folder of its own under `art/`, with what a sheet's JSON names beside
    /// it and an armature's atlas, as the animation is made beside it.
    static func intoGame(_ url: URL, root: URL) throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        if file.path.hasPrefix(root.path + "/") { return String(file.path.dropFirst(root.path.count + 1)) }
        let stem = file.deletingPathExtension().lastPathComponent
        let base = ["_ske", "-sheet", ".sheet"].reduce(stem) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
        let painted = ["psd", "png"].contains(file.pathExtension.lowercased())
        let folder = painted ? "art/source" : "art/\(base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined())"
        let into = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        var companions: [URL] = []
        if file.pathExtension.lowercased() == "json" {
            let siblings = (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            companions = siblings.filter { $0 != file && $0.lastPathComponent.hasPrefix(base) && ["png", "json"].contains($0.pathExtension.lowercased()) }
        }
        for source in [file] + companions {
            let to = into.appending(path: source.lastPathComponent)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: source, to: to)
        }
        return "\(folder)/\(file.lastPathComponent)"
    }

    /// The game's art a prefab can look like: its animations and pictures,
    /// not the sources art was brought in from.
    public var looks: [String] {
        guard let root = document?.url.standardizedFileURL.resolvingSymlinksInPath(),
              let walk = FileManager.default.enumerator(at: root.appending(path: "art", directoryHint: .isDirectory), includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in walk {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else { continue }
            let rel = String(path.dropFirst(root.path.count + 1))
            if rel.hasPrefix("art/source/") || rel.hasSuffix(".normal.png") { continue }
            if rel.hasSuffix(".anim.json") || url.pathExtension.lowercased() == "png" { found.append(rel) }
        }
        // A sheet an animation is cut from isn't a look of its own.
        let sheets = Set(found.filter { $0.hasSuffix(".anim.json") }.flatMap { images.anim($0)?.sheets ?? [] })
        return found.filter { !sheets.contains($0) }.sorted()
    }

    /// A prefab made to look like `look`, standing on the middle of its
    /// bottom edge, as one step.
    public func setLook(_ prefab: String, _ look: String) {
        let size: [Int]? = look.hasSuffix(".anim.json") ? images.anim(look)?.size : images.image(look).map { [$0.width, $0.height] }
        var ops: [GameOp] = [.set(["sprite"], look)]
        if let size, size.count == 2, size[0] > 0 { ops.append(.set(["pivot"], [size[0] / 2, size[1]])) }
        apply(ops, to: "prefab:\(prefab)", label: "Set \(prefab)’s look")
    }

    /// A plane's depth behind the play plane, set from the inspector.
    public func setPlaneDepth(_ plane: String, _ depth: Double) {
        guard let target = roomTarget else { return }
        apply([.set(["planes", "#\(plane)", "depth"], depth)], to: target, label: "Set \(planeName(plane))’s depth")
    }

    /// What hangs in the room's air: `preset` on `plane`, added or taken out.
    public func setAir(_ emitters: [GameEmitter]) {
        guard let target = roomTarget, let room else { return }
        let list = emitters.map { ["preset": $0.preset, "plane": $0.plane] }
        let label = emitters.count > room.particles.count ? "Add \(emitters.last?.preset ?? "air")" : "Take out air"
        // The room's ambience may not say anything yet.
        if !apply([.set(["ambience", "particles"], list)], to: target, label: label) {
            notice = nil
            apply([.set(["ambience"], ["particles": list])], to: target, label: label)
        }
    }

    /// Whether lights fall on a plane.
    public func setPlaneLit(_ plane: String, _ lit: Bool) {
        guard let target = roomTarget else { return }
        apply([.set(["planes", "#\(plane)", "lit"], lit)], to: target, label: lit ? "Light \(planeName(plane))" : "Unlight \(planeName(plane))")
    }

    /// A plane's name as the painter gave it, for an undo step's label.
    private func planeName(_ plane: String) -> String {
        let name = room?.planes.first { $0.id == plane }?.name ?? ""
        return name.isEmpty ? plane : name
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
        if down {
            player.held |= bit
            player.struck |= bit
        } else {
            player.held &= ~bit
        }
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

    private var anims: [String: GameAnim] = [:]
    private var crops: [String: CGImage] = [:]
    private var cut: [String: GameImageParts] = [:]

    /// Everything read forgotten, so files written since are read fresh.
    public func forget() {
        cache = [:]
        missing = []
        anims = [:]
        crops = [:]
        cut = [:]
    }

    /// How an image is cut up (`.img.json`), read once.
    public func parts(_ rel: String) -> GameImageParts? {
        if let hit = cut[rel] { return hit }
        guard !missing.contains(rel), let root,
              let data = try? Data(contentsOf: root.appending(path: rel)), let parts = try? JSONDecoder().decode(GameImageParts.self, from: data) else {
            missing.insert(rel)
            return nil
        }
        cut[rel] = parts
        return parts
    }

    /// What the layout asks of the art: sizes, cut-up images, animations.
    public var art: GameArt {
        GameArt(size: { self.image($0).map { CGSize(width: $0.width, height: $0.height) } },
                parts: { self.parts($0) },
                anim: { self.anim($0) })
    }

    /// An animation, read once.
    public func anim(_ rel: String) -> GameAnim? {
        if let hit = anims[rel] { return hit }
        guard !missing.contains(rel), let root,
              let data = try? Data(contentsOf: root.appending(path: rel)), let anim = try? JSONDecoder().decode(GameAnim.self, from: data) else {
            missing.insert(rel)
            return nil
        }
        anims[rel] = anim
        return anim
    }

    /// Frame `index` of an animation: its part of its sheet, cut once.
    public func frame(_ rel: String, _ index: Int) -> (image: CGImage, frame: GameAnim.Frame)? {
        guard let anim = anim(rel), index >= 0, index < anim.frames.count else { return nil }
        let f = anim.frames[index]
        guard f.rect.count == 4, f.rect[2] > 0, f.rect[3] > 0, f.sheet < anim.sheets.count else { return nil }
        let key = "\(rel)#\(index)"
        if let hit = crops[key] { return (hit, f) }
        guard let sheet = image(anim.sheets[f.sheet]), let cut = sheet.cropping(to: CGRect(x: f.rect[0], y: f.rect[1], width: f.rect[2], height: f.rect[3])) else { return nil }
        crops[key] = cut
        return (cut, f)
    }

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
