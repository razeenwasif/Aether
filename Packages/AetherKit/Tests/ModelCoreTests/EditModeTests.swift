import AetherGraph
import CoreGraphics
import Foundation
import simd
import Testing
@testable import ModelCore
@testable import ModelUI

@MainActor
struct MeshEditSessionTests {
    /// A cube's `.obj` in a folder of its own.
    private func cube() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = try SceneDocument.create(at: folder.appending(path: "Lab.scene.json"))
        return folder.appending(path: try doc.primitive("cube"))
    }

    /// The face of the cage pointing most nearly up.
    private func top(_ edit: MeshEditSession) -> UInt32 {
        let cage = edit.cage
        return (0 ..< UInt32(cage.faceCount)).max { a, b in
            func up(_ f: UInt32) -> Float { cage.face(f).map { cage.position($0).y }.reduce(0, +) }
            return up(a) < up(b)
        }!
    }

    @Test func extrudingInsettingAndCuttingAreStepsAndKeepWhatsChosen() throws {
        let edit = try MeshEditSession(nodeID: "cube-1", url: try cube())
        var steps: [String] = []
        edit.onStep = { steps.append($0) }
        #expect(edit.cage.faceCount == 6 && edit.cage.edges.count == 12 && edit.cage.closed)
        #expect(!edit.extrude(by: 0.5) && edit.refusal != nil, "nothing chosen")

        let up = top(edit)
        edit.choose(.face(up), adding: false)
        #expect(edit.extrude(by: 0.5))
        #expect(edit.faces == [up] && edit.cage.faceCount == 10, "the moved face stays chosen")
        #expect(edit.cage.face(up).allSatisfy { abs(edit.cage.position($0).y - 1) < 1e-5 })
        #expect(edit.inset(by: 0.1))
        #expect(edit.cage.faceCount == 14 && edit.faces == [up])

        edit.show(.edges)
        #expect(edit.edges.count == 4, "the face's edges carried over")
        let one = try #require(edit.edges.first)
        edit.choose(.edge(one), adding: false)
        #expect(edit.loopCut(at: 0.5))
        #expect(edit.part == .edges && !edit.edges.isEmpty, "the new loop chosen")
        #expect(steps == ["Extrude", "Inset", "Loop Cut"])

        edit.show(.faces)
        edit.choose(.face(0), adding: false)
        let before = edit.cage.faceCount
        #expect(edit.delete())
        #expect(edit.cage.faceCount == before - 1 && edit.isEmpty && !edit.cage.closed)
        #expect(edit.undo())
        #expect(edit.cage.faceCount == before && edit.isEmpty, "undo lets go of what was chosen")
        #expect(edit.redo())
    }

    @Test func aSlideIsOneStepWhateverItsLength() throws {
        let edit = try MeshEditSession(nodeID: "cube-1", url: try cube())
        var steps: [String] = []
        edit.onStep = { steps.append($0) }
        let up = top(edit)
        edit.choose(.face(up), adding: false)
        #expect(edit.chosenDirection.y > 0.99)
        #expect(edit.beginSlide(extruding: false))
        edit.slide(by: 0.25)
        edit.slide(by: 0.25)
        edit.endSlide()
        #expect(steps == ["Move"])
        #expect(edit.cage.face(up).allSatisfy { abs(edit.cage.position($0).y - 1) < 1e-5 })

        #expect(edit.beginSlide(extruding: true))
        edit.slide(by: 0.5)
        edit.endSlide()
        #expect(steps == ["Move", "Extrude"], "the slide joins the extrude")
        #expect(edit.cage.faceCount == 10)
        #expect(edit.undo() && edit.cage.faceCount == 6, "one undo takes the extrude and its slide")
    }

    @Test func bevellingTheChosenEdgesChoosesTheNewFaces() throws {
        let edit = try MeshEditSession(nodeID: "cube-1", url: try cube())
        var steps: [String] = []
        edit.onStep = { steps.append($0) }
        #expect(!edit.bevel(by: 0.1) && edit.refusal?.contains("Choose edges") == true)

        edit.show(.edges)
        let one = try #require(edit.cage.edges.first)
        edit.choose(.edge(one), adding: false)
        #expect(!edit.bevel(by: 1.5) && edit.refusal?.contains("wider") == true, "\(edit.refusal ?? "")")
        #expect(steps.isEmpty && edit.cage.faceCount == 6, "a refused bevel changes nothing")
        #expect(edit.bevel(by: 0.1))
        #expect(edit.part == .faces && edit.faces == [6] && edit.cage.faceCount == 7, "the bevel chosen")
        #expect(edit.cage.closed)

        // In Faces, every edge of the face chosen: four bevels, four corners.
        #expect(edit.undo())
        edit.show(.faces)
        edit.choose(.face(top(edit)), adding: false)
        #expect(edit.chosenEdges.count == 4)
        #expect(edit.bevel(by: 0.1))
        #expect(edit.faces.count == 4 && edit.cage.faceCount == 10 && edit.cage.closed)
        #expect(steps == ["Bevel", "Bevel"])
    }

    @Test func choosingCarriesAcrossPartsAndAddsWithShift() throws {
        let edit = try MeshEditSession(nodeID: "cube-1", url: try cube())
        edit.show(.vertices)
        let corners = Array(edit.cage.face(top(edit)))
        for v in corners { edit.choose(.vertex(v), adding: true) }
        #expect(edit.vertices.count == 4)
        edit.choose(.vertex(corners[0]), adding: true)
        #expect(edit.vertices.count == 3, "⇧ again takes it away")
        edit.choose(.vertex(corners[0]), adding: true)
        #expect(edit.chosenFaces == [top(edit)], "four corners make a face")
        edit.show(.faces)
        #expect(edit.faces == [top(edit)])
        edit.chooseAll()
        #expect(edit.faces.count == 6)
        #expect(!edit.loopCut(at: 0.5), "a cut needs one edge")
    }

    @Test func aClickInTheMiddleHitsTheFaceFacingTheEye() throws {
        let edit = try MeshEditSession(nodeID: "cube-1", url: try cube())
        var camera = OrbitCamera()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 4
        let size = CGSize(width: 800, height: 600)
        let hit = edit.hit(CGPoint(x: 400, y: 300), size: size, view: camera.view, world: matrix_identity_float4x4)
        guard case .face(let f) = hit else { Issue.record("no face hit: \(String(describing: hit))"); return }
        #expect(edit.cage.face(f).allSatisfy { abs(edit.cage.position($0).z - 0.5) < 1e-5 }, "the front, at z = 0.5")
        #expect(edit.hit(CGPoint(x: 5, y: 5), size: size, view: camera.view, world: matrix_identity_float4x4) == nil)
        edit.show(.vertices)
        // A front corner is at (±0.5, ±0.5, 0.5): 3.5 m off, on screen.
        let corner = try #require(SceneMath.project(SIMD3(0.5, 0.5, 0.5), view: camera.view, size: size))
        guard case .vertex(let v) = edit.hit(CGPoint(x: corner.x - 3, y: corner.y + 3), size: size, view: camera.view, world: matrix_identity_float4x4) else {
            Issue.record("no corner hit"); return
        }
        #expect(edit.cage.position(v) == SIMD3(0.5, 0.5, 0.5))
        edit.show(.edges)
        guard case .edge = edit.hit(CGPoint(x: 400, y: corner.y + 2), size: size, view: camera.view, world: matrix_identity_float4x4) else {
            Issue.record("no edge hit"); return
        }
    }
}

@MainActor
struct ModelEditModeTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = ProjectGraph(folder: root)
        let model = ModelWorkspaceModel(folder: root.appending(path: "Models", directoryHint: .isDirectory))
        model.project = project
        model.newScene(named: "Room")
        return (model, project)
    }

    @Test func aPrimitiveIsEditedAsACopyAndTheEditsReachTheFile() throws {
        let (model, project) = try setUp()
        let document = try #require(model.document)
        let plain = try String(contentsOf: document.folder.appending(path: "meshes/cube.obj"), encoding: .utf8)
        model.enterEdit()
        let edit = try #require(model.editing, "\(model.notice ?? "no notice")")
        #expect(model.selectedNode?.mesh == "meshes/Cube mesh.obj", "pointed at its own copy")
        #expect(model.notice?.contains("next cube added is still a plain one") == true)

        edit.choose(.face(0), adding: false)
        model.extrudeChosen()
        #expect(model.undoLabel == "Extrude")
        #expect(project.undoLabel(in: project.path(of: edit.url)) == "Extrude", "the project's one history")
        model.undo()
        #expect(edit.cage.faceCount == 6)
        model.redo()
        #expect(edit.cage.faceCount == 10)

        model.exitEdit()
        #expect(model.editing == nil)
        let written = try String(contentsOf: document.folder.appending(path: "meshes/Cube mesh.obj"), encoding: .utf8)
        #expect(written.split(separator: "\n").filter { $0.hasPrefix("f ") }.count == 10)
        #expect(try String(contentsOf: document.folder.appending(path: "meshes/cube.obj"), encoding: .utf8) == plain, "the primitive is untouched")
        let node = try #require(model.selectedNode)
        #expect(document.mesh(for: node).triangleCount == 20, "drawn again from the file")
        #expect(model.undoLabel == "Edit Cube’s Mesh", "back to the scene's steps")

        model.enterEdit()
        #expect(model.selectedNode?.mesh == "meshes/Cube mesh.obj", "its own now: no second copy")
        model.exitEdit()
    }

    @Test func aMeshSharedWithAnotherObjectIsCopiedToo() throws {
        let (model, _) = try setUp()
        let cube = try #require(model.selectedNode)
        model.enterEdit()
        model.exitEdit()
        let own = try #require(model.selectedNode?.mesh)
        let twin = try #require(model.change(.add(kind: "mesh", name: "Twin", mesh: own), label: "Add Twin"))
        model.choose(twin)
        model.enterEdit()
        #expect(model.selectedNode?.mesh == "meshes/Twin mesh.obj")
        #expect(model.notice?.contains("Cube draws \(own) too") == true)
        model.choose(cube.id)
        #expect(model.editing == nil, "choosing another object leaves Edit mode")
    }

    @Test func draggingTheChosenFaceSlidesItAndOptionExtrudes() throws {
        let (model, _) = try setUp()
        let size = CGSize(width: 800, height: 600)
        model.camera.yaw = 0
        model.camera.pitch = 0
        model.camera.distance = 4
        model.enterEdit()
        let edit = try #require(model.editing)
        let middle = CGPoint(x: 400, y: 300)
        model.pick(at: middle, in: size)
        let front = try #require(edit.faces.first)
        #expect(!model.pressToSlide(at: CGPoint(x: 5, y: 5), in: size, extruding: false), "off what's chosen: the view turns")

        // The front faces the eye, so its normal points at it: up the screen slides it.
        #expect(model.pressToSlide(at: middle, in: size, extruding: false))
        model.dragSlide(to: CGPoint(x: 400, y: 300 - 2))
        #expect(model.undoLabel == nil, "not started until the pointer moves")
        model.dragSlide(to: CGPoint(x: 400, y: 250))
        model.endSlide()
        #expect(model.undoLabel == "Move")
        let z = edit.cage.face(front).map { edit.cage.position($0).z }
        #expect(z.allSatisfy { $0 > 0.6 }, "toward the eye: \(z)")

        #expect(model.pressToSlide(at: middle, in: size, extruding: true))
        model.dragSlide(to: CGPoint(x: 400, y: 260))
        model.endSlide()
        #expect(model.undoLabel == "Extrude" && edit.cage.faceCount == 10)
    }
}
