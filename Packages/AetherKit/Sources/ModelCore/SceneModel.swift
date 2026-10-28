import Foundation

/// One entry in an object's modifier stack, as `proton-scene` reads it.
public struct SceneModifier: Codable, Sendable, Equatable {
    /// `mirror`, `array`, `subdivide`, or a kind from a later version.
    public var kind: String
    public var off: Bool
    /// Whether this build can apply it: one it can't is kept, and shown so.
    public var known: Bool
    public var axis: String
    public var weld: Bool
    public var count: Int
    public var offset: [Double]
    public var levels: Int

    public var title: String {
        switch kind {
        case "mirror": "Mirror"
        case "array": "Array"
        case "subdivide": "Subdivide"
        default: kind.capitalized
        }
    }

    /// The kinds this build can apply, in the order they're offered.
    public static let kinds = ["mirror", "array", "subdivide"]
}

/// One object of a scene: what the outliner draws and the inspector edits.
public struct SceneNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// `mesh`, `camera`, `light`, `empty`, or a kind from a later version.
    public var kind: String
    /// Empty for a root.
    public var parent: String
    public var material: String
    public var modifiers: [SceneModifier]
    /// What its geometry is known by: the mesh's path, with the object's id
    /// when a stack runs on it.
    public var geometry: String
    /// Its `.obj`, relative to the scene, or empty.
    public var mesh: String
    /// Metres, degrees, and a multiplier.
    public var position: [Double]
    public var rotation: [Double]
    public var scale: [Double]
    /// How deep it sits, and how many name it as their parent.
    public var depth: Int
    public var children: Int

    public var kindTitle: String {
        switch kind {
        case "mesh": "Mesh"
        case "camera": "Camera"
        case "light": "Light"
        case "empty": "Empty"
        default: kind.capitalized
        }
    }

    /// What its triangles depend on: its mesh and its stack, so a change to
    /// either draws it again.
    public var shape: String {
        mesh + "|" + modifiers.map { "\($0.kind),\($0.off),\($0.axis),\($0.weld),\($0.count),\($0.offset),\($0.levels)" }.joined(separator: ";")
    }
}

/// A material, by its name; its graph is compiled into a `SceneShader`.
public struct SceneMaterial: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
}

/// One instruction of a compiled material (`proton_scene::Op`).
public enum ShaderOp: Decodable, Sendable, Equatable {
    case constant([Float])
    case position
    case noise(at: Int, scale: Float, detail: Float)
    case checker(at: Int, scale: Float)
    case mix(a: Int, b: Int, fac: Int)
    /// An instruction from a later core: drawn grey, not guessed at.
    case unknown(String)

    private enum Keys: String, CodingKey { case op, value, at, scale, detail, a, b, fac }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "constant": self = .constant(try c.decode([Float].self, forKey: .value))
        case "position": self = .position
        case "noise": self = .noise(at: try c.decode(Int.self, forKey: .at), scale: try c.decode(Float.self, forKey: .scale), detail: try c.decode(Float.self, forKey: .detail))
        case "checker": self = .checker(at: try c.decode(Int.self, forKey: .at), scale: try c.decode(Float.self, forKey: .scale))
        case "mix": self = .mix(a: try c.decode(Int.self, forKey: .a), b: try c.decode(Int.self, forKey: .b), fac: try c.decode(Int.self, forKey: .fac))
        case let other: self = .unknown(other)
        }
    }
}

/// A compiled material: its program, and the registers that hold the
/// answer. `problem` says why there is none.
public struct SceneShader: Decodable, Sendable, Equatable {
    public var id: String
    public var ops: [ShaderOp]
    public var base: Int
    public var metallic: Int
    public var roughness: Int
    public var problem: String
}

/// What the core says the scene is now.
public struct SceneState: Decodable, Sendable, Equatable {
    public var objects: [SceneNode]
    public var materials: [SceneMaterial]
    public var shaders: [SceneShader]
    public var undo: String?
    public var redo: String?
    public var dirty: Bool

    public static let empty = SceneState(objects: [], materials: [], shaders: [], undo: nil, redo: nil, dirty: false)
}

/// Which part of a transform an edit sets.
public enum ScenePart: String, Codable, Sendable, CaseIterable {
    case position, rotation, scale

    public var title: String { rawValue.capitalized }
}

/// A change to a scene, in the bridge's shape: one undo step each.
public enum SceneEdit: Encodable, Sendable, Equatable {
    case add(kind: String, name: String, parent: String = "", mesh: String = "", position: [Double]? = nil)
    case remove(String)
    case rename(String, name: String)
    case reparent(String, parent: String)
    case setTransform(String, part: ScenePart, to: [Double])
    case setMesh(String, path: String)
    case addModifier(String, kind: String)
    case removeModifier(String, index: Int)
    case moveModifier(String, index: Int, to: Int)
    case setModifier(String, index: Int, field: String, value: String)

    private enum Keys: String, CodingKey { case edit, kind, name, parent, mesh, position, id, part, to, path, index, field, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .add(kind, name, parent, mesh, position):
            try c.encode("add", forKey: .edit)
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(parent, forKey: .parent)
            try c.encode(mesh, forKey: .mesh)
            try c.encodeIfPresent(position, forKey: .position)
        case .remove(let id):
            try c.encode("remove", forKey: .edit)
            try c.encode(id, forKey: .id)
        case let .rename(id, name):
            try c.encode("rename", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
        case let .reparent(id, parent):
            try c.encode("reparent", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(parent, forKey: .parent)
        case let .setTransform(id, part, to):
            try c.encode("setTransform", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(part, forKey: .part)
            try c.encode(to, forKey: .to)
        case let .setMesh(id, path):
            try c.encode("setMesh", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(path, forKey: .path)
        case let .addModifier(id, kind):
            try c.encode("addModifier", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
        case let .removeModifier(id, index):
            try c.encode("removeModifier", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(index, forKey: .index)
        case let .moveModifier(id, index, to):
            try c.encode("moveModifier", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(index, forKey: .index)
            try c.encode(to, forKey: .to)
        case let .setModifier(id, index, field, value):
            try c.encode("setModifier", forKey: .edit)
            try c.encode(id, forKey: .id)
            try c.encode(index, forKey: .index)
            try c.encode(field, forKey: .field)
            try c.encode(value, forKey: .value)
        }
    }
}

/// An object's triangles, ready for the GPU; or why there are none.
public struct SceneMeshData: Sendable {
    public var positions: [Float]
    public var normals: [Float]
    public var triangles: [UInt32]
    /// Least x, y, z, then most; empty when unknown.
    public var bounds: [Float]
    public var closed: Bool
    public var problem: String?

    public var triangleCount: Int { triangles.count / 3 }

    public init(positions: [Float], normals: [Float], triangles: [UInt32], bounds: [Float], closed: Bool, problem: String?) {
        self.positions = positions
        self.normals = normals
        self.triangles = triangles
        self.bounds = bounds
        self.closed = closed
        self.problem = problem
    }
}
