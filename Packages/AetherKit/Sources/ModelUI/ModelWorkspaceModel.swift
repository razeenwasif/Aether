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
/// chosen, and the camera — Proton's Modeling, in Object mode, on Metal.
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
        saveNow()
        if let path = documentPath { project?.forget(document: path) }
        document = nil
        selected = nil
        refreshList()
    }

    /// Another project's scenes: the one open is saved and let go.
    public func switchFolder(to url: URL) {
        close()
        folder = url
        refreshList()
    }

    private func show(_ doc: SceneDocument) {
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

    private func scheduleSave() {
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
        if let id = change(.add(kind: kind, name: name, parent: parent, mesh: mesh), label: "Add \(name)") {
            selected = id
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
        guard let document else { return }
        if let project { project.undo(in: project.path(of: document.url)) { document.undo() } } else { document.undo() }
        scheduleSave()
    }

    public func redo() {
        guard let document else { return }
        if let project { project.redo(in: project.path(of: document.url)) { document.redo() } } else { document.redo() }
        scheduleSave()
    }

    public var undoLabel: String? {
        guard let project else { return document?.state.undo }
        return documentPath.flatMap { project.undoLabel(in: $0) }
    }

    public var redoLabel: String? {
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

    /// Choose what's under a point of the viewport, or nothing.
    public func pick(at point: CGPoint, in size: CGSize) {
        selected = SceneMath.pick(point, size: size, view: camera.view, boxes: boxes())
    }

    /// The camera aimed at everything (f).
    public func frameAll() {
        camera.frame(boxes().flatMap(\.corners))
    }

    /// The camera aimed at the object chosen, or at everything.
    public func frameSelected() {
        guard let selected, let box = boxes().first(where: { $0.id == selected }) else { return frameAll() }
        camera.frame(box.corners)
    }

    // MARK: Keys

    /// The viewport's keys: f frames, ⌫ removes, ⎋ lets go. Answers whether
    /// the key was used; not while typing.
    public func handleKey(_ event: NSEvent) -> Bool {
        guard document != nil, !(NSApplication.shared.keyWindow?.firstResponder is NSTextView) else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
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
