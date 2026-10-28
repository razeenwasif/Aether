import DiffuseBridge
import Foundation
import Observation

/// A scene open for editing: Proton's `scene.proton.json`, edited through
/// the core, one edit an undo step. What it holds is read back from the core
/// after each change; an object's triangles are asked for when its mesh or
/// stack changes, and kept.
@MainActor
@Observable
public final class SceneDocument {
    public private(set) var state: SceneState
    /// The scene's file.
    public private(set) var url: URL
    /// Why the last edit was refused, in the core's words.
    public private(set) var refusal: String?
    /// Bumped when anything drawn may have changed.
    public private(set) var revision = 0

    /// Told of each new step in its history, by name: so the project can
    /// keep every document's steps in one history.
    @ObservationIgnored public var onStep: ((String) -> Void)?

    @ObservationIgnored let editor: SceneEditor
    @ObservationIgnored private var meshes: [String: (shape: String, data: SceneMeshData)] = [:]
    @ObservationIgnored private let encoder = JSONEncoder()

    private init(editor: SceneEditor, url: URL) {
        self.editor = editor
        self.url = url
        state = .empty
        refresh()
    }

    /// A new scene at `url`, written at once so its meshes can be found
    /// beside it.
    public static func create(at url: URL) throws -> SceneDocument {
        let doc = SceneDocument(editor: SceneEditor.create(), url: url)
        try doc.save()
        return doc
    }

    public static func open(_ url: URL) throws -> SceneDocument {
        SceneDocument(editor: try SceneEditor.open(path: url.path), url: url)
    }

    /// Its name: the file's, without `.scene.json`.
    public var name: String {
        var stem = url.lastPathComponent
        for suffix in [".json", ".scene", ".proton"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
        return stem
    }

    /// The folder its meshes are named from.
    public var folder: URL { url.deletingLastPathComponent() }

    public func node(_ id: String) -> SceneNode? { state.objects.first { $0.id == id } }

    // MARK: Changes

    /// Apply `edit` as one undo step named `label`. Answers whether anything
    /// changed and an added object's id, or `nil` with the reason in
    /// `refusal`.
    @discardableResult
    public func apply(_ edit: SceneEdit, label: String) -> (changed: Bool, id: String?)? {
        struct Answer: Decodable { var changed: Bool; var id: String? }
        do {
            let json = String(decoding: try encoder.encode(edit), as: UTF8.self)
            let answer = try JSONDecoder().decode(Answer.self, from: Data(editor.edit(editJson: json, label: label).utf8))
            refusal = nil
            if answer.changed {
                refresh()
                onStep?(label)
            }
            return (answer.changed, answer.id)
        } catch {
            refusal = Self.describe(error)
            return nil
        }
    }

    @discardableResult
    public func undo() -> Bool {
        guard editor.undo() != nil else { return false }
        refresh()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard editor.redo() != nil else { return false }
        refresh()
        return true
    }

    public func save() throws {
        try editor.save(path: url.path)
        refresh()
    }

    public func save(as newURL: URL) throws {
        try editor.save(path: newURL.path)
        url = newURL
        meshes = [:]
        refresh()
    }

    // MARK: Geometry

    /// An object's triangles, its stack applied: asked of the core the first
    /// time, and again only when its mesh or stack changes.
    public func mesh(for node: SceneNode) -> SceneMeshData {
        if let kept = meshes[node.id], kept.shape == node.shape { return kept.data }
        let m = editor.mesh(id: node.id)
        let data = SceneMeshData(positions: m.positions, normals: m.normals, triangles: m.triangles, bounds: m.bounds, closed: m.closed, problem: m.problem)
        meshes[node.id] = (node.shape, data)
        return data
    }

    /// Forget every mesh read, so files changed on disk are read again.
    public func reloadMeshes() {
        meshes = [:]
        revision &+= 1
    }

    /// Write a primitive's `.obj` into the scene's `meshes/` folder, unless
    /// one is there; answers its path relative to the scene.
    public func primitive(_ kind: String) throws -> String {
        guard let obj = scenePrimitive(kind: kind) else { throw CocoaError(.featureUnsupported) }
        let relative = "meshes/\(kind).obj"
        let file = folder.appending(path: relative)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(obj.utf8).write(to: file, options: .atomic)
        }
        return relative
    }

    // MARK: Reading back

    private func refresh() {
        if let fresh = try? JSONDecoder().decode(SceneState.self, from: Data(editor.view().utf8)) {
            state = fresh
            // Objects gone take their triangles with them.
            let ids = Set(fresh.objects.map(\.id))
            meshes = meshes.filter { ids.contains($0.key) }
        }
        revision &+= 1
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? DiffuseError {
            switch e {
            case .Failed(let message), .Gateway(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
