import AetherGraph
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ModelCore
@testable import ModelUI

@MainActor
struct MaterialLayerTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = ProjectGraph(folder: root)
        let model = ModelWorkspaceModel(folder: root.appending(path: "Models", directoryHint: .isDirectory))
        model.project = project
        model.newScene(named: "Room")
        return (model, project)
    }

    @Test func aNewMaterialIsAStackAndEachLayerAStep() throws {
        let (model, project) = try setUp()
        #expect(model.selectedMaterial == nil)
        model.addLayer(.noise)
        let material = try #require(model.selectedMaterial, "adding a layer to nothing makes a material first")
        #expect(material.name == "Cube Material")
        var stack = try #require(model.stack(of: material.id))
        #expect(stack.base == .plain && stack.layers.map(\.pattern) == [.noise])
        #expect(model.undoLabel == "Add Noise Layer")
        #expect(project.undoLabel(in: model.documentPath) == "Add Noise Layer")
        let shader = try #require(model.document?.state.shaders.first { $0.id == material.id })
        #expect(shader.problem.isEmpty && !shader.ops.isEmpty)

        model.addLayer(.checker)
        model.moveLayer(at: 1, by: -1)
        stack = try #require(model.stack(of: material.id))
        #expect(stack.layers.map(\.pattern) == [.checker, .noise], "moved down the stack")
        model.removeLayer(at: 0)
        #expect(model.stack(of: material.id)?.layers.map(\.pattern) == [.noise])
        model.undo()
        #expect(model.stack(of: material.id)?.layers.count == 2)
    }

    @Test func aColourDraggedIsOneStep() throws {
        let (model, project) = try setUp()
        model.newMaterial()
        let material = try #require(model.selectedMaterial)
        for red in stride(from: 0.2, through: 0.9, by: 0.1) {
            model.editStack("Base Colour") { $0.base.color = [red, 0.1, 0.1] }
        }
        #expect(model.stack(of: material.id)?.base.color.first.map { abs($0 - 0.9) < 1e-6 } == true)
        #expect(project.undoLabel(in: model.documentPath) == "Base Colour")
        model.undo()
        #expect(model.stack(of: material.id)?.base == .plain, "the whole drag undone at once")
        #expect(model.undoLabel == "New Material")

        // The same control a while later is a step of its own.
        model.editStack("Base Colour") { $0.base.color = [0.5, 0.5, 0.5] }
        model.lastLayerEdit = (model.lastLayerEdit!.key, Date().addingTimeInterval(-5))
        model.editStack("Base Colour") { $0.base.color = [0.6, 0.6, 0.6] }
        model.undo()
        #expect(model.stack(of: material.id)?.base.color == [0.5, 0.5, 0.5])
    }

    @Test func anotherObjectCanWearItAndAGraphIsKeptUntilReplaced() throws {
        let (model, _) = try setUp()
        model.newMaterial()
        let paint = try #require(model.selectedMaterial)
        model.add(.sphere)
        model.wear(paint.id)
        #expect(model.selectedMaterial?.id == paint.id && model.undoLabel == "Wear Cube Material")
        model.wear("")
        #expect(model.selectedMaterial == nil && model.undoLabel == "No Material")

        // A scene from Proton with a graph made by hand.
        let document = try #require(model.document)
        let url = document.url
        model.close()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["materials"] = [[
            "id": "alu", "name": "Brushed aluminium",
            "nodes": [["id": "n", "kind": "noise", "at": [0, 0], "params": ["scale": 6]],
                      ["id": "b", "kind": "principled", "at": [1, 0], "params": ["baseColor": [0.55, 0.56, 0.58], "metallic": 0.9, "roughness": 0.24]],
                      ["id": "o", "kind": "output", "at": [2, 0]]],
            "links": [["from": "n:fac", "to": "b:roughness"], ["from": "b:bsdf", "to": "o:surface"]],
        ]]
        var objects = json["objects"] as! [[String: Any]]
        objects[0]["material"] = "alu"
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        model.open(url)
        model.selected = model.document?.state.objects.first?.id
        #expect(model.selectedMaterial?.nodes?.count == 3)
        #expect(model.stack(of: "alu") == nil, "not a stack")
        model.addLayer(.solid)
        #expect(model.notice?.contains("replace it with layers first") == true)
        model.layersFromGraph()
        let stack = try #require(model.stack(of: "alu"))
        #expect(stack.base == SceneSurface(color: [0.55, 0.56, 0.58], metallic: 0.9, roughness: 0.24) && stack.layers.isEmpty)
        model.undo()
        #expect(model.stack(of: "alu") == nil, "undo brings the graph back")
    }

    @Test func aStacksProgramCompilesOnTheGPUAndItsColoursAreNotInIt() throws {
        let (model, _) = try setUp()
        for pattern in LayerPattern.allCases { model.addLayer(pattern) }
        let id = try #require(model.selectedMaterial?.id)
        let shader = try #require(model.document?.state.shaders.first { $0.id == id })
        let source = SceneShaderSource.surface(shader)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: source, options: nil)
        #expect(library.makeFunction(name: "surfaceFragment") != nil)

        let key = SceneShaderSource.key(shader)
        let before = SceneShaderSource.constants(of: shader)
        model.editStack("Noise Colour") { $0.layers[1].surface.color = [0.9, 0.05, 0.6] }
        let after = try #require(model.document?.state.shaders.first { $0.id == id })
        #expect(SceneShaderSource.key(after) == key, "a new colour, the same program")
        #expect(SceneShaderSource.constants(of: after) != before)
        #expect(SceneShaderSource.surface(after) == source)
    }

    @Test func theGraphDrawerDrawsEveryNodeAndWireWithNothingOnTopOfAnything() throws {
        let (model, _) = try setUp()
        for pattern in LayerPattern.allCases { model.addLayer(pattern) }
        let material = try #require(model.selectedMaterial)
        let nodes = try #require(material.nodes)
        #expect(nodes.contains { $0.kind == "noise" } && nodes.contains { $0.kind == "principled" })
        let surface = try #require(nodes.first { $0.kind == "principled" })
        #expect(surface.params.contains { $0.name == "baseColor" && $0.value == .color([0.8, 0.8, 0.8]) }, "settings read with their values")

        let layout = GraphLayout(material)
        #expect(layout.boxes.count == nodes.count)
        #expect(layout.wires.count == material.links?.count, "every wire lands on a row")
        for (i, a) in layout.boxes.enumerated() {
            for b in layout.boxes[(i + 1)...] {
                #expect(!a.frame.intersects(b.frame), "\(a.id) and \(b.id) overlap")
            }
        }
        let fit = layout.fit(in: CGSize(width: 800, height: 250))
        let scale = layout.scale(in: CGSize(width: 800, height: 250))
        for box in layout.boxes {
            let p = fit(box.frame.origin), q = fit(CGPoint(x: box.frame.maxX, y: box.frame.maxY))
            #expect(p.x >= 0 && p.y >= 0 && q.x <= 800 && q.y <= 250, "fitted inside the drawer")
        }
        #expect(scale > 0 && scale <= 1.2)

        model.toggleGraph()
        #expect(model.graphOpen)
    }

    @Test func aMaterialIsRenamedAndTheUnwornGoInOneStep() throws {
        let (model, project) = try setUp()
        model.newMaterial()
        model.renameMaterial("  Oak  ")
        #expect(model.selectedMaterial?.name == "Oak" && model.undoLabel == "Rename Material")
        model.renameMaterial("   ")
        #expect(model.notice?.contains("empty") == true)
        model.newMaterial()
        model.newMaterial()
        #expect(model.unwornMaterials.map(\.name) == ["Oak", "Cube Material"], "the newest is worn")
        model.removeUnwornMaterials()
        #expect(model.document?.state.materials.count == 1 && model.unwornMaterials.isEmpty)
        #expect(project.undoLabel(in: model.documentPath) == "Remove Unworn Materials")
        model.undo()
        #expect(model.document?.state.materials.count == 3, "both back with one undo")
        model.removeUnwornMaterials()
        model.removeUnwornMaterials()
        #expect(model.notice == "Every material is worn by something.")
    }
}
