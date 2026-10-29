import AetherGraph
import CoreGraphics
import Foundation
import simd
import Testing
@testable import ModelCore
@testable import ModelUI

struct SceneMathTests {
    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ within: Float = 1e-4) -> Bool { simd_length(a - b) < within }

    private func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }

    @Test func transformsScaleThenTurnThenMove() {
        // Proton's order: scale, then R = Rz·Ry·Rx in degrees, then move.
        let m = SceneMath.compose(position: [1, 2, 3], rotation: [0, 90, 0], scale: [2, 2, 2])
        #expect(close(apply(m, [1, 0, 0]), [1, 2, 1]), "x scaled to 2, turned onto -z, moved")
        let turned = SceneMath.compose(position: [0, 0, 0], rotation: [90, 0, 90], scale: [1, 1, 1])
        #expect(close(apply(turned, [0, 1, 0]), [0, 0, 1]), "x first: y onto z, then z stays put under Rz")
        #expect(SceneMath.compose(position: [], rotation: [], scale: []) == matrix_identity_float4x4, "missing parts are the identity")
    }

    @Test func childrenFollowTheirParents() {
        func node(_ id: String, parent: String = "", position: [Double], depth: Int = 0) -> SceneNode {
            SceneNode(id: id, name: id, kind: "empty", parent: parent, material: "", modifiers: [], geometry: "", mesh: "", position: position, rotation: [0, 0, 0], scale: [1, 1, 1], depth: depth, children: 0, fov: 50, light: nil)
        }
        let worlds = SceneMath.worlds([node("a", position: [0, 5, 0]), node("b", parent: "a", position: [1, 0, 0], depth: 1)])
        #expect(close(apply(worlds["b"]!, .zero), [1, 5, 0]))
    }

    private func doubles(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }

    @Test func aClickChoosesTheNearestBoxUnderIt() {
        let camera = OrbitCamera()
        let size = CGSize(width: 800, height: 600)
        let middle = CGPoint(x: 400, y: 300)
        let near = SceneMath.corners(bounds: [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5], world: matrix_identity_float4x4)
        // The same box, farther back along the camera's line.
        let back = SceneMath.corners(bounds: nil, world: SceneMath.compose(position: doubles(-camera.eye / 2), rotation: [], scale: []))
        #expect(SceneMath.pick(middle, size: size, view: camera.view, boxes: [("back", back), ("near", near)]) == "near")
        #expect(SceneMath.pick(CGPoint(x: 5, y: 5), size: size, view: camera.view, boxes: [("near", near)]) == nil, "a corner of the view is empty")
        let behind = SceneMath.corners(bounds: nil, world: SceneMath.compose(position: doubles(camera.eye * 2), rotation: [], scale: []))
        #expect(SceneMath.pick(middle, size: size, view: camera.view, boxes: [("behind", behind)]) == nil, "what's behind the camera isn't seen")
    }

    @Test func framingSeesEverything() {
        var camera = OrbitCamera()
        let points: [SIMD3<Float>] = [[-3, 0, -1], [5, 2, 1]]
        camera.frame(points)
        #expect(close(camera.target, [1, 1, 0]))
        #expect(camera.distance > simd_length(points[1] - points[0]) / 2, "back far enough")
        camera.zoom(by: 1e6)
        #expect(camera.distance == 400, "held to a range")
        camera.orbit(dx: 0, dy: 1e6)
        #expect(camera.pitch == 1.5, "short of the pole")
    }
}

struct SceneShaderSourceTests {
    @Test func aMaterialBecomesOneLineAnInstruction() {
        let shader = SceneShader(id: "m", ops: [.constant([1, 0, 0]), .position, .noise(at: 1, scale: 4, detail: 3), .mix(a: 0, b: 2, fac: 2)], base: 3, metallic: 0, roughness: 2, problem: "")
        let source = SceneShaderSource.surface(shader)
        #expect(source.contains("float3 r0 = k[0].xyz;"), "a constant is read from the buffer")
        #expect(SceneShaderSource.constants(of: shader) == [SIMD4(1, 0, 0, 1)])
        #expect(source.contains("float3 r2 = float3(fbm(r1 * 4.0, 3));"))
        #expect(source.contains("float3 base = r3;"))
        #expect(SceneShaderSource.key(shader) != SceneShaderSource.key(nil))
        #expect(SceneShaderSource.surface(nil).contains("float3 base = float3(0.78);"), "no material: the plain grey")
        let broken = SceneShader(id: "m", ops: [.position], base: 0, metallic: 0, roughness: 0, problem: "a loop")
        #expect(SceneShaderSource.key(broken) == "plain", "one that couldn't compile is drawn plain")
        #expect(SceneShaderSource.num(.nan) == "0.0" && SceneShaderSource.num(0.25) == "0.25")
    }
}

@MainActor
struct SceneDocumentTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func editsAreStepsAndTrianglesAreKept() throws {
        let doc = try SceneDocument.create(at: try folder().appending(path: "Lab.scene.json"))
        #expect(doc.name == "Lab")
        var steps: [String] = []
        doc.onStep = { steps.append($0) }
        let mesh = try doc.primitive("cube")
        #expect(mesh == "meshes/cube.obj")
        let id = try #require(doc.apply(.add(kind: "mesh", name: "Box", mesh: mesh), label: "Add Box")?.id)
        let box = try #require(doc.node(id))
        let triangles = doc.mesh(for: box)
        #expect(triangles.triangleCount == 12 && triangles.closed && triangles.bounds == [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5])

        doc.apply(.addModifier(id, kind: "subdivide"), label: "Add Subdivide")
        doc.apply(.setModifier(id, index: 0, field: "levels", value: "2"), label: "Modifier")
        let smooth = try #require(doc.node(id))
        #expect(smooth.shape != box.shape, "a stack change is a new shape")
        #expect(doc.mesh(for: smooth).triangleCount == 12 * 16, "two levels, four times each")

        #expect(doc.apply(.rename(id, name: "Box"), label: "Rename")?.changed == false, "the same name is no step")
        #expect(steps == ["Add Box", "Add Subdivide", "Modifier"])
        #expect(doc.apply(.remove("nobody"), label: "Remove") == nil && doc.refusal != nil, "refused, with the core's reason")

        #expect(doc.undo())
        #expect(doc.node(id)?.modifiers.first?.levels != 2)
        #expect(doc.redo())
        #expect(doc.mesh(for: doc.node(id)!).triangleCount == 192)

        try doc.save()
        #expect(!doc.state.dirty)
        let again = try SceneDocument.open(doc.url)
        #expect(again.node(id)?.modifiers.count == 1, "the stack is in the file; the .obj never changed")
    }

    @Test func aMeshNotThereIsDrawnAsABox() throws {
        let doc = try SceneDocument.create(at: try folder().appending(path: "Gone.scene.json"))
        let id = try #require(doc.apply(.add(kind: "mesh", name: "Ghost", mesh: "meshes/ghost.obj"), label: "Add")?.id)
        #expect(doc.mesh(for: doc.node(id)!).problem != nil)
    }
}

@MainActor
struct ModelWorkspaceTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = ProjectGraph(folder: root)
        let model = ModelWorkspaceModel(folder: root.appending(path: "Models", directoryHint: .isDirectory))
        model.project = project
        return (model, project)
    }

    @Test func aNewSceneHasACubeAndNothingToUndo() throws {
        let (model, _) = try setUp()
        model.newScene(named: "Room")
        let document = try #require(model.document)
        #expect(document.state.objects.map(\.name) == ["Cube"])
        #expect(model.selected == document.state.objects.first?.id)
        #expect(model.undoLabel == nil, "making it isn't a step")
        #expect(model.scenes.map(\.name) == ["Room"])
        model.newScene(named: "Room")
        #expect(model.document?.name == "Room 2", "never over another")
    }

    @Test func addingRemovingAndUndoingGoThroughTheProject() throws {
        let (model, project) = try setUp()
        model.newScene(named: "Room")
        model.add(.empty)
        let empty = try #require(model.selected)
        model.add(.sphere)
        let sphere = try #require(model.selectedNode)
        #expect(sphere.parent == empty, "added under the empty chosen")
        #expect(sphere.name == "Sphere")
        model.add(.sphere)
        #expect(model.selectedNode?.name == "Sphere 2")
        #expect(model.selectedNode?.parent == "", "a mesh chosen isn't a parent")

        model.selected = empty
        model.removeSelected()
        #expect(model.selected == nil)
        #expect(model.document?.state.objects.map(\.name) == ["Cube", "Sphere 2"], "the empty took what was under it")
        #expect(model.undoLabel == "Remove Empty")
        #expect(project.undoLabel(in: model.documentPath) == "Remove Empty", "one history, the project's")
        model.undo()
        #expect(model.document?.state.objects.count == 4)
        model.redo()
        #expect(model.document?.state.objects.count == 2)

        model.saveNow()
        #expect(model.document?.state.dirty == false)
    }

    @Test func aMeshFromElsewhereIsCopiedBesideTheScene() throws {
        let (model, _) = try setUp()
        model.newScene(named: "Room")
        let document = try #require(model.document)
        let outside = FileManager.default.temporaryDirectory.appending(path: "aether-\(UUID().uuidString).obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: outside)
        #expect(try model.relativeMesh(outside, in: document) == "meshes/\(outside.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: document.folder.appending(path: "meshes/\(outside.lastPathComponent)").path))
        #expect(try model.relativeMesh(document.folder.appending(path: "meshes/cube.obj"), in: document) == "meshes/cube.obj", "one inside is named as it is")
    }

    @Test func framingAndPickingFindTheCube() throws {
        let (model, _) = try setUp()
        model.newScene(named: "Room")
        let cube = model.selected
        model.selected = nil
        model.frameAll()
        model.pick(at: CGPoint(x: 400, y: 300), in: CGSize(width: 800, height: 600))
        #expect(model.selected == cube, "framed, it's in the middle")
        model.pick(at: CGPoint(x: 2, y: 2), in: CGSize(width: 800, height: 600))
        #expect(model.selected == nil)
    }
}
