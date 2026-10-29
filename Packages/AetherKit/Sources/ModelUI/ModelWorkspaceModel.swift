import AetherGraph
import AppKit
import Foundation
import ModelCore
import Observation
import simd

/// A scene in the project's `Models/` folder.
public struct SceneFile: Identifiable, Hashable, Sendable {
    public var url: URL
    public var modified: Date
    public var id: URL { url }

    public var name: String {
        var stem = url.lastPathComponent
        for suffix in [".json", ".scene"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
        return stem
    }
}

/// What can be added to a scene: a primitive mesh, or a thing with no
/// surface of its own.
public enum SceneAddition: String, CaseIterable, Identifiable, Sendable {
    case cube, sphere, cylinder, cone, torus, plane, empty, light, camera

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var isMesh: Bool { ![.empty, .light, .camera].contains(self) }
    public var symbol: String {
        switch self {
        case .cube: "cube"
        case .sphere: "circle"
        case .cylinder: "cylinder"
        case .cone: "cone"
        case .torus: "circle.circle"
        case .plane: "square"
        case .empty: "move.3d"
        case .light: "lightbulb"
        case .camera: "camera"
        }
    }
}

/// The Model workspace: the scenes in the project, the scene open, the object
/// chosen, and the camera — Proton's Modeling, on Metal — and Edit mode, for
/// the chosen object's mesh (`ModelEditMode.swift`).
@MainActor
@Observable
public final class ModelWorkspaceModel {
    public private(set) var document: SceneDocument?
    public private(set) var scenes: [SceneFile] = []
    /// The object chosen, by id.
    public var selected: String?
    public var camera = OrbitCamera()
    public var navigatorOpen = true
    public var inspectorOpen = true
    public var notice: String?
    public var askingForNew = false
    /// What the last frame drew and how long the GPU took: §7's budget, read.
    public internal(set) var stats = ModelStats()
    /// The chosen object's mesh, open in Edit mode (⇥).
    public internal(set) var editing: MeshEditSession?
    /// How far Extrude pulls, how far in Inset goes, how wide a bevel is,
    /// and where along its edges a loop cut falls.
    public var extrudeDistance = 0.25
    public var insetAmount = 0.1
    public var bevelWidth = 0.05
    public var cutAt = 0.5
    /// A drag sliding what's chosen: the last point, the way the slide goes
    /// on screen in points a metre, and whether it has started (it starts,
    /// and extrudes, only once the pointer moves).
    @ObservationIgnored var slideState: (last: CGPoint, perMetre: CGVector, extruding: Bool, started: Bool)?
    /// The last change to a material's layers: the same one again within a
    /// second (a colour dragged, a slider slid) joins its step.
    @ObservationIgnored var lastLayerEdit: (key: String, at: Date)?
    /// The graph drawer: the chosen object's material as its node graph.
    public var graphOpen = false {
        didSet { if graphOpen { renderOpen = false } }
    }
    /// The render drawer: the last render, and how the next is made.
    public var renderOpen = false {
        didSet { if renderOpen { graphOpen = false } }
    }
    public var renderSize: RenderSize = .square
    /// A render's background left clear, for a picture to sit on another.
    public var renderTransparent = false
    /// A camera object a render looks through; `nil`, the view's camera.
    public var renderCamera: String?
    /// A floor under everything in a render, for shadows to fall on.
    public var renderFloor = true
    public var renderShadows = true
    public internal(set) var lastRender: Rendered?
    /// The GPU drawing renders: its own, so a render needn't wait on the view.
    @ObservationIgnored var renderer: ModelRenderer?

    /// Where scenes go: the project's `Models/`.
    public private(set) var folder: URL
    /// The project: every document's steps in one history.
    public var project: ProjectGraph?

    @ObservationIgnored private var saving: Task<Void, Never>?

    public init(folder: URL = ModelWorkspaceModel.defaultFolder) {
        self.folder = folder
        refreshList()
    }

    /// `~/Documents/Aether/Models`, the default project's.
    public nonisolated static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "Aether/Models", directoryHint: .isDirectory)
    }

    public var selectedNode: SceneNode? { selected.flatMap { document?.node($0) } }

    // MARK: Scenes

    public func refreshList() {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        scenes = found.filter { $0.lastPathComponent.hasSuffix(".scene.json") }.map { url in
            SceneFile(url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    /// A new scene named `name`, made unique in the folder, with a cube in it
    /// so there's something to turn round.
    public func newScene(named name: String) {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        var url = folder.appending(path: "\(base).scene.json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).scene.json")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            show(try SceneDocument.create(at: url))
            add(.cube)
            // Making the scene isn't a step to undo.
            if let path = documentPath { project?.forget(document: path) }
            refreshList()
        } catch {
            notice = "Couldn’t make the scene: \(SceneDocument.describe(error))"
        }
    }

    public func open(_ url: URL) {
        guard url != document?.url else { return }
        do {
            show(try SceneDocument.open(url))
        } catch {
            notice = "Couldn’t open \(url.lastPathComponent): \(SceneDocument.describe(error))"
        }
    }

    /// Back to the scenes, the new scene's name to type.
    public func askForNew() {
        close()
        askingForNew = true
    }

    public func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open a Scene"
        panel.directoryURL = folder
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Back to the scenes.
    public func close() {
        exitEdit()
        saveNow()
        if let path = documentPath { project?.forget(document: path) }
        document = nil
        selected = nil
        lastRender = nil
        renderOpen = false
        refreshList()
    }

    /// Another project's scenes: the one open is saved and let go.
    public func switchFolder(to url: URL) {
        close()
        folder = url
        refreshList()
    }

    private func show(_ doc: SceneDocument) {
        exitEdit()
        saveNow()
        if let path = documentPath { project?.forget(document: path) }
        document = doc
        selected = doc.state.objects.first?.id
        doc.onStep = { [weak self, weak doc] label in
            guard let self, let doc else { return }
            if let project { try? project.documentStepped(project.path(of: doc.url), label: label) }
            scheduleSave()
        }
        camera = OrbitCamera()
        frameAll()
    }

    public var documentPath: String? {
        guard let project, let document else { return nil }
        return project.path(of: document.url)
    }

    // MARK: Saving, as Proton's: an edit reaches the disk

    func scheduleSave() {
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write the scene now, if it has changes.
    public func saveNow() {
        saving?.cancel()
        saving = nil
        saveEdit()
        guard let document, document.state.dirty else { return }
        do {
            try document.save()
            if let path = documentPath { project?.documentSaved(path) }
        } catch {
            notice = "Couldn’t save \(document.name): \(SceneDocument.describe(error))"
        }
    }

    // MARK: Editing

    /// Apply an edit, saying why when it's refused.
    @discardableResult
    public func change(_ edit: SceneEdit, label: String) -> String? {
        guard let document else { return nil }
        guard let answer = document.apply(edit, label: label) else {
            notice = document.refusal
            return nil
        }
        return answer.id
    }

    /// Something added to the scene, under the object chosen when it's an
    /// empty, and chosen.
    public func add(_ addition: SceneAddition) {
        exitEdit()
        guard let document else { return }
        var mesh = ""
        if addition.isMesh {
            do {
                mesh = try document.primitive(addition.rawValue)
            } catch {
                return notice = "Couldn’t make the \(addition.rawValue): \(SceneDocument.describe(error))"
            }
        }
        let parent = selectedNode.flatMap { $0.kind == "empty" ? $0.id : nil } ?? ""
        let kind = addition.isMesh ? "mesh" : addition.rawValue
        let name = uniqueName(addition.title)
        // A light above what's there, rather than inside the cube at the
        // origin; a camera where the view is, so it sees what you see.
        var position: [Double]?
        if addition == .light {
            let corners = boxes().filter { box in document.node(box.id)?.kind == "mesh" }.flatMap(\.corners)
            let top = corners.map(\.y).max() ?? 0
            let middle = corners.isEmpty ? SIMD3<Float>(0, 0, 0) : corners.reduce(SIMD3<Float>(0, 0, 0), +) / Float(corners.count)
            position = [Double(middle.x) + 2, Double(top) + 3, Double(middle.z) + 2].map { ($0 * 1000).rounded() / 1000 }
        }
        let label = "Add \(name)"
        if let id = change(.add(kind: kind, name: name, parent: parent, mesh: mesh, position: position), label: label) {
            selected = id
            if addition == .camera { placeCamera(label: label, joining: true, adopt: false) }
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(document?.state.objects.map(\.name) ?? [])
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// The object chosen taken out, and everything under it.
    public func removeSelected() {
        exitEdit()
        guard let node = selectedNode else { return }
        if change(.remove(node.id), label: "Remove \(node.name)") != nil || document?.node(node.id) == nil {
            selected = nil
        }
    }

    public func setTransform(_ id: String, _ part: ScenePart, _ value: [Double]) {
        change(.setTransform(id, part: part, to: value), label: part.title)
    }

    /// Point an object at an `.obj` chosen: one outside the scene's folder is
    /// copied into its `meshes/` first, as a scene names meshes beside it.
    public func chooseMesh(for id: String) {
        guard let document else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Mesh"
        panel.message = "A Wavefront .obj: the scene names it, and never writes it."
        panel.allowedContentTypes = [.init(filenameExtension: "obj") ?? .data]
        panel.directoryURL = document.folder.appending(path: "meshes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            change(.setMesh(id, path: try relativeMesh(url, in: document)), label: "Mesh")
        } catch {
            notice = "Couldn’t use \(url.lastPathComponent): \(SceneDocument.describe(error))"
        }
    }

    /// `url`'s path relative to the scene's folder, copying it into `meshes/`
    /// when it's elsewhere.
    func relativeMesh(_ url: URL, in document: SceneDocument) throws -> String {
        let root = document.folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        let meshes = document.folder.appending(path: "meshes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meshes, withIntermediateDirectories: true)
        var target = meshes.appending(path: url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = meshes.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n).obj")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: target)
        return "meshes/\(target.lastPathComponent)"
    }

    public func addModifier(_ kind: String, to id: String) {
        change(.addModifier(id, kind: kind), label: "Add \(kind.capitalized)")
    }

    public func setModifier(_ id: String, _ index: Int, _ field: String, _ value: String) {
        change(.setModifier(id, index: index, field: field, value: value), label: "Modifier")
    }

    // MARK: Undo, through the project's one history

    public func undo() {
        if let edit = editing { return editUndo(edit, redo: false) }
        guard let document else { return }
        if let project { project.undo(in: project.path(of: document.url)) { document.undo() } } else { document.undo() }
        scheduleSave()
    }

    public func redo() {
        if let edit = editing { return editUndo(edit, redo: true) }
        guard let document else { return }
        if let project { project.redo(in: project.path(of: document.url)) { document.redo() } } else { document.redo() }
        scheduleSave()
    }

    public var undoLabel: String? {
        if let edit = editing { return project.flatMap { $0.undoLabel(in: $0.path(of: edit.url)) } ?? edit.cage.undo }
        guard let project else { return document?.state.undo }
        return documentPath.flatMap { project.undoLabel(in: $0) }
    }

    public var redoLabel: String? {
        if let edit = editing { return project.flatMap { $0.redoLabel(in: $0.path(of: edit.url)) } ?? edit.cage.redo }
        guard let project else { return document?.state.redo }
        return documentPath.flatMap { project.redoLabel(in: $0) }
    }

    // MARK: The viewport

    /// Every object's box in the world, for picking and framing.
    public func boxes() -> [(id: String, corners: [SIMD3<Float>])] {
        guard let document else { return [] }
        let worlds = SceneMath.worlds(document.state.objects)
        return document.state.objects.map { node in
            let bounds = node.kind == "mesh" && !node.mesh.isEmpty ? document.mesh(for: node).bounds : nil
            return (node.id, SceneMath.corners(bounds: bounds, world: worlds[node.id] ?? matrix_identity_float4x4))
        }
    }

    /// Choose what's under a point of the viewport, or nothing; in Edit
    /// mode, the corner, edge or face, `adding` to what's chosen.
    public func pick(at point: CGPoint, in size: CGSize, adding: Bool = false) {
        if let edit = editing, let world = editWorld {
            return edit.choose(edit.hit(point, size: size, view: camera.view, world: world), adding: adding)
        }
        selected = SceneMath.pick(point, size: size, view: camera.view, boxes: boxes())
    }

    /// Choose an object (the outliner): Edit mode ends when it's another.
    public func choose(_ id: String) {
        if editing?.nodeID != id { exitEdit() }
        selected = id
    }

    /// The camera aimed at everything (f).
    public func frameAll() {
        camera.frame(boxes().flatMap(\.corners))
    }

    /// The camera aimed at the object chosen, or at everything.
    public func frameSelected() {
        if let edit = editing, let world = editWorld {
            let corners = edit.chosenVertices.isEmpty ? (0 ..< UInt32(edit.cage.vertexCount)).map { $0 } : edit.chosenVertices
            let points = corners.map { v in
                let p = world * SIMD4(edit.cage.position(v), 1)
                return SIMD3(p.x, p.y, p.z)
            }
            return camera.frame(points)
        }
        guard let selected, let box = boxes().first(where: { $0.id == selected }) else { return frameAll() }
        camera.frame(box.corners)
    }

    // MARK: Keys

    /// The viewport's keys: f frames, ⌫ removes, ⎋ lets go. Answers whether
    /// the key was used; not while typing.
    public func handleKey(_ event: NSEvent) -> Bool {
        guard document != nil, !(NSApplication.shared.keyWindow?.firstResponder is NSTextView) else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        if event.keyCode == 48 {
            guard editing != nil || canEdit else { return false }
            toggleEdit()
            return true
        }
        if editing != nil { return handleEditKey(event) }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (_, "f"):
            selected == nil ? frameAll() : frameSelected()
        case (_, "a") where event.modifierFlags.contains(.shift):
            frameAll()
        case (51, _), (117, _):
            removeSelected()
        case (53, _):
            selected = nil
        default:
            return false
        }
        return true
    }
}

/// What the viewport drew last: for the budget and for the person.
public struct ModelStats: Equatable, Sendable {
    public var triangles = 0
    public var objects = 0
    /// The GPU's time for the last frame, in milliseconds.
    public var gpuMilliseconds: Double = 0

    public init(triangles: Int = 0, objects: Int = 0, gpuMilliseconds: Double = 0) {
        self.triangles = triangles
        self.objects = objects
        self.gpuMilliseconds = gpuMilliseconds
    }
}
