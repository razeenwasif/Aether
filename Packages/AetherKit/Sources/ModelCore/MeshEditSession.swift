import CoreGraphics
import DiffuseBridge
import Foundation
import Observation
import simd

/// What Edit mode chooses: corners, edges or faces (1, 2, 3).
public enum EditPart: String, CaseIterable, Identifiable, Sendable {
    case vertices, edges, faces

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var key: String {
        switch self {
        case .vertices: "1"
        case .edges: "2"
        case .faces: "3"
        }
    }
}

/// An edge, lower vertex first.
public struct MeshEdge: Hashable, Sendable {
    public let a: UInt32
    public let b: UInt32

    public init(_ a: UInt32, _ b: UInt32) {
        (self.a, self.b) = a < b ? (a, b) : (b, a)
    }
}

/// What's under the pointer in Edit mode.
public enum EditHit: Equatable, Sendable {
    case vertex(UInt32)
    case edge(MeshEdge)
    case face(UInt32)
}

/// A mesh as Edit mode sees it: corners, faces, edges, and triangles to draw.
public struct MeshCageData: Sendable {
    public var positions: [Float] = []
    public var faces: [UInt32] = []
    public var faceSizes: [UInt32] = []
    public var faceStarts: [Int] = []
    public var edges: [MeshEdge] = []
    public var triangles: [UInt32] = []
    public var triangleFaces: [UInt32] = []
    public var closed = false
    public var undo: String?
    public var redo: String?
    public var steps = 0
    public var dirty = false

    public init() {}

    init(_ c: MeshCage) {
        positions = c.positions
        faces = c.faces
        faceSizes = c.faceSizes
        var at = 0
        faceStarts = c.faceSizes.map { size in
            defer { at += Int(size) }
            return at
        }
        edges = stride(from: 0, to: c.edges.count - 1, by: 2).map { MeshEdge(c.edges[$0], c.edges[$0 + 1]) }
        triangles = c.triangles
        triangleFaces = c.triangleFaces
        closed = c.closed
        undo = c.undo
        redo = c.redo
        steps = Int(c.steps)
        dirty = c.dirty
    }

    public var vertexCount: Int { positions.count / 3 }
    public var faceCount: Int { faceSizes.count }

    public func face(_ f: UInt32) -> ArraySlice<UInt32> {
        let i = Int(f)
        guard i < faceStarts.count else { return [] }
        return faces[faceStarts[i] ..< faceStarts[i] + Int(faceSizes[i])]
    }

    public func position(_ v: UInt32) -> SIMD3<Float> {
        let i = Int(v) * 3
        return SIMD3(positions[i], positions[i + 1], positions[i + 2])
    }

    /// A face's edges, in its winding.
    public func edges(of f: UInt32) -> [MeshEdge] {
        let ring = Array(face(f))
        return ring.indices.map { MeshEdge(ring[$0], ring[($0 + 1) % ring.count]) }
    }
}

/// A mesh open in Edit mode: the `.obj` an object draws, edited through the
/// core, each edit an undo step, and what's chosen in it.
@MainActor
@Observable
public final class MeshEditSession {
    /// The object whose mesh this is.
    public let nodeID: String
    public private(set) var url: URL
    public private(set) var cage = MeshCageData()
    public private(set) var part: EditPart = .faces
    public var vertices: Set<UInt32> = []
    public var edges: Set<MeshEdge> = []
    public var faces: Set<UInt32> = []
    /// Why the last edit was refused.
    public private(set) var refusal: String?
    /// Bumped when anything drawn may have changed.
    public private(set) var revision = 0
    /// Bumped when the mesh itself changes, not what's chosen.
    public private(set) var shapeRevision = 0

    /// Told of each new step, by name.
    @ObservationIgnored public var onStep: ((String) -> Void)?
    @ObservationIgnored let editor: MeshEditor
    /// The way a drag slides what's chosen, fixed when it starts.
    @ObservationIgnored private var sliding: (vertices: [UInt32], along: SIMD3<Double>, label: String, started: Bool)?

    public init(nodeID: String, url: URL) throws {
        self.nodeID = nodeID
        self.url = url
        editor = try MeshEditor.open(path: url.path)
        refresh()
    }

    /// What writing this file would drop.
    public var dropped: [String] { editor.dropped() }

    // MARK: What's chosen

    public var isEmpty: Bool {
        switch part {
        case .vertices: vertices.isEmpty
        case .edges: edges.isEmpty
        case .faces: faces.isEmpty
        }
    }

    public var chosenCount: Int {
        switch part {
        case .vertices: vertices.count
        case .edges: edges.count
        case .faces: faces.count
        }
    }

    /// Every corner of what's chosen.
    public var chosenVertices: [UInt32] {
        switch part {
        case .vertices: return vertices.sorted()
        case .edges: return Set(edges.flatMap { [$0.a, $0.b] }).sorted()
        case .faces: return Set(faces.flatMap { cage.face($0) }).sorted()
        }
    }

    /// The faces what's chosen makes up: those with every corner or every
    /// edge chosen, outside Faces.
    public var chosenFaces: [UInt32] {
        switch part {
        case .vertices: return editor.facesOfVertices(vertices: vertices.sorted())
        case .edges: return editor.facesOfEdges(edges: edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) }.flatMap { [$0.a, $0.b] })
        case .faces: return faces.sorted()
        }
    }

    /// The edges what's chosen makes up: those with both ends chosen, in
    /// Vertices; every edge of each face, in Faces.
    public var chosenEdges: [MeshEdge] {
        let set: Set<MeshEdge> = switch part {
        case .vertices: Set(cage.edges.filter { vertices.contains($0.a) && vertices.contains($0.b) })
        case .edges: edges
        case .faces: Set(faces.flatMap { cage.edges(of: $0) })
        }
        return set.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    /// Choose corners, edges or faces, carrying over what was chosen.
    public func show(_ next: EditPart) {
        guard next != part else { return }
        let corners = Set(chosenVertices)
        let made = chosenFaces
        part = next
        vertices = []
        edges = []
        faces = []
        switch next {
        case .vertices: vertices = corners
        case .edges: edges = Set(cage.edges.filter { corners.contains($0.a) && corners.contains($0.b) })
        case .faces: faces = Set(made)
        }
        revision &+= 1
    }

    /// What a click hit, chosen; with `adding`, added or taken away.
    public func choose(_ hit: EditHit?, adding: Bool) {
        if !adding {
            vertices = []
            edges = []
            faces = []
        }
        switch hit {
        case .vertex(let v): toggle(&vertices, v)
        case .edge(let e): toggle(&edges, e)
        case .face(let f): toggle(&faces, f)
        case nil: break
        }
        revision &+= 1
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ item: T) {
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
    }

    public func chooseAll() {
        switch part {
        case .vertices: vertices = Set(0 ..< UInt32(cage.vertexCount))
        case .edges: edges = Set(cage.edges)
        case .faces: faces = Set(0 ..< UInt32(cage.faceCount))
        }
        revision &+= 1
    }

    public func chooseNothing() {
        vertices = []
        edges = []
        faces = []
        revision &+= 1
    }

    /// Whether `hit` is among what's chosen: a drag from it slides them.
    public func isChosen(_ hit: EditHit?) -> Bool {
        switch hit {
        case .vertex(let v): vertices.contains(v)
        case .edge(let e): edges.contains(e)
        case .face(let f): faces.contains(f)
        case nil: false
        }
    }

    // MARK: Edits

    /// Pull the chosen faces out by `distance`. Refused, with why, when no
    /// face is chosen.
    @discardableResult
    public func extrude(by distance: Double) -> Bool {
        let chosen = chosenFaces
        guard !chosen.isEmpty else { return refuse("Choose faces to extrude: in Vertices or Edges, every corner or edge of a face.") }
        let kept = editor.extrude(faces: chosen, distance: distance)
        settle(.faces, faces: kept, step: "Extrude")
        return true
    }

    @discardableResult
    public func inset(by amount: Double) -> Bool {
        let chosen = chosenFaces
        guard !chosen.isEmpty else { return refuse("Choose faces to inset.") }
        guard amount > 0 else { return refuse("Inset by more than nothing.") }
        let kept = editor.inset(faces: chosen, amount: amount)
        settle(.faces, faces: kept, step: "Inset")
        return true
    }

    /// A loop cut through the edge chosen (or the two corners chosen), `t`
    /// of the way across.
    @discardableResult
    public func loopCut(at t: Double) -> Bool {
        let edge: MeshEdge?
        switch part {
        case .edges: edge = edges.count == 1 ? edges.first : nil
        case .vertices:
            let pair = vertices.sorted()
            edge = pair.count == 2 && cage.edges.contains(MeshEdge(pair[0], pair[1])) ? MeshEdge(pair[0], pair[1]) : nil
        case .faces: edge = nil
        }
        guard let edge else { return refuse("Choose one edge to cut across: the loop runs through the four-sided faces beside it.") }
        do {
            let made = try editor.loopCut(a: edge.a, b: edge.b, t: t)
            let loop = stride(from: 0, to: made.count - 1, by: 2).map { MeshEdge(made[$0], made[$0 + 1]) }
            settle(.edges, edges: Set(loop), step: "Loop Cut")
            return true
        } catch {
            let why = SceneDocument.describe(error)
            return refuse(why.prefix(1).uppercased() + why.dropFirst() + ".")
        }
    }

    /// Bevel the chosen edges `width` wide, one segment; the new faces are
    /// chosen after.
    @discardableResult
    public func bevel(by width: Double) -> Bool {
        let chosen = chosenEdges
        guard !chosen.isEmpty else { return refuse("Choose edges to bevel: in Faces, every edge of the faces chosen is bevelled.") }
        guard width > 0 else { return refuse("Bevel by more than nothing.") }
        do {
            let made = try editor.bevel(edges: chosen.flatMap { [$0.a, $0.b] }, width: width)
            settle(.faces, faces: made, step: "Bevel")
            return true
        } catch {
            let why = SceneDocument.describe(error)
            return refuse(why.prefix(1).uppercased() + why.dropFirst() + ".")
        }
    }

    /// Take out what's chosen.
    @discardableResult
    public func delete() -> Bool {
        guard !isEmpty else { return refuse("Choose something to delete.") }
        switch part {
        case .vertices: editor.deleteVertices(vertices: vertices.sorted())
        case .edges: editor.deleteEdges(edges: edges.flatMap { [$0.a, $0.b] })
        case .faces: editor.deleteFaces(faces: faces.sorted())
        }
        settle(part, step: "Delete")
        return true
    }

    /// Start sliding what's chosen along its normal; with `extruding`, the
    /// chosen faces are pulled out first, and the slide is part of that step.
    @discardableResult
    public func beginSlide(extruding: Bool) -> Bool {
        if extruding {
            guard extrude(by: 0) else { return false }
        }
        let corners = chosenVertices
        guard !corners.isEmpty else { return false }
        let d = editor.direction(vertices: corners)
        sliding = (corners, SIMD3(d[0], d[1], d[2]), extruding ? "Extrude" : "Move", extruding)
        return true
    }

    /// The way the slide goes, in the mesh's own space.
    public var slideDirection: SIMD3<Double>? { sliding?.along }

    /// The way what's chosen would slide: the faces round it, together.
    public var chosenDirection: SIMD3<Double> {
        let d = editor.direction(vertices: chosenVertices)
        return SIMD3(d[0], d[1], d[2])
    }

    /// Slide on by `distance` metres.
    public func slide(by distance: Double) {
        guard var s = sliding, distance != 0 else { return }
        let d = s.along * distance
        let made = editor.moveVertices(vertices: s.vertices, dx: d.x, dy: d.y, dz: d.z, label: s.label, continuing: s.started)
        s.started = true
        sliding = s
        refresh()
        if made { onStep?(s.label) }
    }

    public func endSlide() {
        sliding = nil
    }

    // MARK: Undo and saving

    @discardableResult
    public func undo() -> Bool {
        guard editor.undo() != nil else { return false }
        chooseNothing()
        refresh()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard editor.redo() != nil else { return false }
        chooseNothing()
        refresh()
        return true
    }

    public var dirty: Bool { cage.dirty }

    /// Write the mesh; with `newURL`, there, and it lives there from now on.
    public func save(as newURL: URL? = nil) throws {
        try editor.save(path: newURL?.path)
        if let newURL { url = newURL }
        refresh()
    }

    // MARK: Picking

    /// What's under `point` (points, y down) for the part being chosen: a
    /// face by the ray through it, a corner or edge near it on screen, among
    /// the face hit's own when one is.
    public func hit(_ point: CGPoint, size: CGSize, view: simd_float4x4, world: simd_float4x4) -> EditHit? {
        let modelView = view * world
        let focal = Float(size.height) * 0.5 / tan(SceneMath.fov / 2)
        let (w, h) = (Float(size.width), Float(size.height))
        let eye: [SIMD3<Float>] = (0 ..< cage.vertexCount).map { v in
            let p = modelView * SIMD4(cage.position(UInt32(v)), 1)
            return SIMD3(p.x, p.y, p.z)
        }
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            guard p.z < -0.01 else { return nil }
            return SIMD2(w / 2 + focal * p.x / -p.z, h / 2 - focal * p.y / -p.z)
        }
        let at = SIMD2(Float(point.x), Float(point.y))
        let ray = simd_normalize(SIMD3((at.x - w / 2) / focal, -(at.y - h / 2) / focal, -1))

        // The nearest face along the ray.
        var nearest: (face: UInt32, t: Float)?
        for i in stride(from: 0, to: cage.triangles.count - 2, by: 3) {
            let (a, b, c) = (eye[Int(cage.triangles[i])], eye[Int(cage.triangles[i + 1])], eye[Int(cage.triangles[i + 2])])
            if let t = Self.intersect(ray, a, b, c), t < nearest?.t ?? .infinity {
                nearest = (cage.triangleFaces[i / 3], t)
            }
        }
        switch part {
        case .faces:
            return nearest.map { .face($0.face) }
        case .vertices:
            let candidates = nearest.map { Array(cage.face($0.face)) } ?? (0 ..< UInt32(cage.vertexCount)).map { $0 }
            var best: (v: UInt32, d: Float)?
            for v in candidates {
                guard let s = screen(eye[Int(v)]) else { continue }
                let d = simd_distance(s, at)
                if d <= 12, d < best?.d ?? .infinity { best = (v, d) }
            }
            return best.map { .vertex($0.v) }
        case .edges:
            let candidates = nearest.map { cage.edges(of: $0.face) } ?? cage.edges
            var best: (e: MeshEdge, d: Float)?
            for e in candidates {
                guard let p = screen(eye[Int(e.a)]), let q = screen(eye[Int(e.b)]) else { continue }
                let d = Self.distance(at, p, q)
                if d <= 10, d < best?.d ?? .infinity { best = (e, d) }
            }
            return best.map { .edge($0.e) }
        }
    }

    /// Where a ray from the eye meets a triangle, Möller–Trumbore; either side.
    static func intersect(_ dir: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(dir, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let inv = 1 / det
        let s = -a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-4 ? t : nil
    }

    /// From a point to a segment, on screen.
    static func distance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = simd_clamp(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-6), 0, 1)
        return simd_distance(p, a + ab * t)
    }

    // MARK: Reading back

    private func refuse(_ why: String) -> Bool {
        refusal = why
        return false
    }

    /// After an edit: what it answers chosen, in its part.
    private func settle(_ next: EditPart, faces kept: [UInt32] = [], edges loop: Set<MeshEdge> = [], step: String) {
        refusal = nil
        let before = cage.steps
        refresh()
        part = next
        vertices = []
        edges = loop
        faces = Set(kept)
        revision &+= 1
        // A new step only when the core kept one.
        if cage.steps != before { onStep?(step) }
    }

    private func refresh() {
        cage = MeshCageData(editor.cage())
        // What's chosen past the end of the mesh is let go.
        vertices = vertices.filter { Int($0) < cage.vertexCount }
        faces = faces.filter { Int($0) < cage.faceCount }
        let known = Set(cage.edges)
        edges = edges.filter { known.contains($0) }
        revision &+= 1
        shapeRevision &+= 1
    }
}
