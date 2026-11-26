import PhotonGraph
import CoreGraphics
import Foundation
import simd
import Testing
@testable import ModelCore
@testable import ModelUI

@MainActor
struct RenderTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "photon-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = ProjectGraph(folder: root)
        let model = ModelWorkspaceModel(folder: root.appending(path: "Models", directoryHint: .isDirectory))
        model.project = project
        model.newScene(named: "Room")
        return (model, project)
    }

    /// A picture's pixel at (`x`, `y`) from its top left, as RGBA.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return out
    }

    /// The project's assets once both have a version (publishing is async).
    private func published(_ project: ProjectGraph, versions: Int) async throws -> [Asset] {
        for _ in 0..<200 {
            let made = project.assets.filter { $0.source == .model }
            if made.count == 2, made.allSatisfy({ $0.newest?.number == versions }) { return made }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("not published: \(project.assets.map { "\($0.name) \($0.newest?.number ?? 0)" })")
        return []
    }

    @Test func aRenderIsTheSceneAndItsDepthWrittenAndPublished() async throws {
        let (model, project) = try setUp()
        model.frameAll()
        model.renderSize = .wide
        model.render()
        await model.renderFinished()
        let last = try #require(model.lastRender, "\(model.notice ?? "no render")")
        #expect(model.renderOpen)
        #expect((last.beauty.width, last.beauty.height) == (1536, 1024) && (last.depth.width, last.depth.height) == (1536, 1024))

        // The cube in the middle, the background at the corner.
        let (mx, my) = (768, 512)
        let middle = pixel(last.beauty, mx, my), corner = pixel(last.beauty, 4, 4)
        #expect(middle[0] > 80 && corner[0] < 20, "lit cube \(middle) on dark ground \(corner)")
        let near = pixel(last.depth, mx, my), far = pixel(last.depth, 4, 4)
        let (nearGrey, farGrey) = (Int(near[0]), Int(far[0]))
        #expect(nearGrey > 20 && farGrey == 0, "depth: the cube light, nothing black (\(near), \(far))")
        #expect(near[0] == near[1] && near[1] == near[2], "grey")

        for url in [last.files.beauty, last.files.depth] {
            #expect(FileManager.default.fileExists(atPath: url.path) && url.path.contains("/renders/"))
        }
        let assets = try await published(project, versions: 1)
        #expect(Set(assets.map(\.name)) == ["Room Render", "Room Depth"])
        #expect(assets.allSatisfy { $0.newest?.width == 1536 && $0.newest?.height == 1024 })
        #expect(assets.allSatisfy { ModelWorkspaceModel.scenePath(ofRender: $0.document) == model.documentPath })

        // Moved, rendered again: new versions of the same two assets.
        model.camera.yaw += 40
        model.render()
        await model.renderFinished()
        _ = try await published(project, versions: 2)
        #expect(project.assets.count == 2)
        #expect(model.lastRender?.versions?.beauty == 2)
    }

    @Test func aClearBackgroundIsClear() async throws {
        let (model, _) = try setUp()
        model.frameAll()
        model.renderSize = .square
        model.renderTransparent = true
        model.render()
        await model.renderFinished()
        let last = try #require(model.lastRender)
        #expect(pixel(last.beauty, 3, 3)[3] == 0, "clear where nothing is")
        #expect(pixel(last.beauty, 512, 512)[3] == 255, "solid where the cube is")
        #expect(pixel(last.depth, 3, 3)[3] == 255, "the depth pass is always solid")
    }

    @Test func nothingToRenderWithoutAScene() async throws {
        let (model, _) = try setUp()
        model.close()
        model.render()
        await model.renderFinished()
        #expect(model.lastRender == nil && model.notice == "Open a scene to render it.")
    }

    /// A picture's mean brightness, 0 to 255.
    private func brightness(_ image: CGImage) -> Double {
        let (w, h) = (64, 64)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 0, to: out.count, by: 4).map { Double(out[$0]) }.reduce(0, +) / Double(w * h)
    }

    @Test func aTurnReadsBackAsTheDegreesItWasMadeFrom() {
        for r in [[0.0, 0, 0], [30, 0, 0], [0, -45, 0], [10, 20, 30], [-60, 120, 15], [90, 10, 0]] {
            let m = SceneMath.compose(position: [0, 0, 0], rotation: r, scale: [2, 2, 2])
            let turn = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / 2, SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / 2, SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / 2)
            let back = SceneMath.compose(position: [0, 0, 0], rotation: SceneMath.degrees(of: turn), scale: [2, 2, 2])
            for c in 0..<4 { #expect(simd_length(back[c] - m[c]) < 1e-3, "\(r) → \(SceneMath.degrees(of: turn))") }
        }
    }

    @Test func aCameraTakesTheViewAndARenderLooksThroughIt() async throws {
        let (model, _) = try setUp()
        let cube = try #require(model.selected)
        model.frameAll()
        model.camera.yaw = 0.7
        model.camera.pitch = 0.4
        model.add(.camera)
        let camera = try #require(model.selectedNode)
        #expect(camera.kind == "camera" && camera.fov == 50)
        let added = SceneMath.view(through: SceneMath.worlds(model.document!.state.objects)[camera.id]!)
        #expect(simd_length(added[3] - model.camera.view[3]) < 1e-3, "a camera added starts where the view is")
        #expect(model.undoLabel == "Add Camera" && model.renderCamera == nil, "one step, and renders still use the view")
        let first = try #require(model.selectedNode?.position)
        model.camera.yaw += 0.4
        model.cameraFromView()
        let placed = try #require(model.selectedNode)
        let world = SceneMath.worlds(model.document!.state.objects)[placed.id]!
        let through = SceneMath.view(through: world)
        for c in 0..<4 { #expect(simd_length(through[c] - model.camera.view[c]) < 1e-3, "the camera sees what the view saw") }
        #expect(model.undoLabel == "Camera from the View" && model.renderCamera == placed.id, "one step, and renders look through it")
        model.undo()
        #expect(model.selectedNode?.position == first, "the whole of it undone at once")
        model.redo()

        // The view turned away: a render through the camera still sees the cube.
        model.renderSize = .square
        model.renderFloor = false
        model.camera.yaw += 3
        model.camera.target = SIMD3(40, 0, 0)
        model.render()
        await model.renderFinished()
        let through1 = try #require(model.lastRender)
        #expect(pixel(through1.beauty, 512, 512)[0] > 60, "the cube, through the camera")
        model.renderCamera = nil
        model.render()
        await model.renderFinished()
        #expect(pixel(model.lastRender!.beauty, 512, 512)[0] < 20, "the view, turned away, sees nothing")

        model.selected = placed.id
        model.setFov(20)
        #expect(model.selectedNode?.fov == 20)
        model.selected = cube
    }

    @Test func shadowsFallOnTheFloorAndAFloorIsInTheDepth() async throws {
        let (model, _) = try setUp()
        model.frameAll()
        model.add(.light)
        let lamp = try #require(model.selectedNode)
        #expect(lamp.light == SceneLight(kind: "point", color: [1, 1, 1], strength: 20))
        #expect(lamp.position[1] > 2, "above the cube, not inside it")
        model.setLightKind("sun")
        #expect(model.selectedNode?.light?.strength == 3, "a sun's own strength")
        model.editLight("Light Strength") { $0.strength = 5 }
        model.setLightKind("point")
        #expect(model.selectedNode?.light?.strength == 5, "one changed by hand is kept")
        model.setLightKind("sun")
        model.editLight("Light Strength") { $0.strength = 3 }
        model.change(.setTransform(lamp.id, part: .rotation, to: [-50, 220, 0]), label: "Turn")
        #expect(model.selectedNode?.light?.kind == "sun")

        model.renderSize = .square
        model.render()
        await model.renderFinished()
        let shadowed = try #require(model.lastRender)
        model.renderShadows = false
        model.render()
        await model.renderFinished()
        let plain = try #require(model.lastRender)
        #expect(brightness(shadowed.beauty) < brightness(plain.beauty) - 0.5, "a shadow darkens the floor: \(brightness(shadowed.beauty)) vs \(brightness(plain.beauty))")

        // A point light beyond the cube: its shadow, from a perspective map,
        // falls towards the camera too.
        model.renderShadows = true
        model.setLightKind("point")
        model.editLight("Light Strength") { $0.strength = 40 }
        model.change(.setTransform(lamp.id, part: .position, to: [-2.5, 3, -2.5]), label: "Move")
        model.render()
        await model.renderFinished()
        let pointShadowed = try #require(model.lastRender)
        model.renderShadows = false
        model.render()
        await model.renderFinished()
        let pointPlain = try #require(model.lastRender)
        #expect(brightness(pointShadowed.beauty) < brightness(pointPlain.beauty) - 0.5, "a point light's shadow: \(brightness(pointShadowed.beauty)) vs \(brightness(pointPlain.beauty))")

        model.renderFloor = false
        model.render()
        await model.renderFinished()
        let bare = try #require(model.lastRender)
        #expect(brightness(plain.depth) > brightness(bare.depth) + 5, "the floor is in the depth pass")
        #expect(brightness(plain.beauty) > brightness(bare.beauty), "and in the picture")
    }

    @Test func aLightsColourDraggedIsOneStep() async throws {
        let (model, project) = try setUp()
        model.add(.light)
        for g in stride(from: 0.9, through: 0.3, by: -0.1) {
            model.editLight("Light Colour") { $0.color = [1, g, 0.5] }
        }
        #expect(project.undoLabel(in: model.documentPath) == "Light Colour")
        model.undo()
        #expect(model.selectedNode?.light?.color == [1, 1, 1])
    }
}
