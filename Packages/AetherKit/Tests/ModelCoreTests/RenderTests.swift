import AetherGraph
import CoreGraphics
import Foundation
import Testing
@testable import ModelCore
@testable import ModelUI

@MainActor
struct RenderTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        _ = try await published(project, versions: 2)
        #expect(project.assets.count == 2)
        #expect(model.lastRender?.versions?.beauty == 2)
    }

    @Test func aClearBackgroundIsClear() throws {
        let (model, _) = try setUp()
        model.frameAll()
        model.renderSize = .square
        model.renderTransparent = true
        model.render()
        let last = try #require(model.lastRender)
        #expect(pixel(last.beauty, 3, 3)[3] == 0, "clear where nothing is")
        #expect(pixel(last.beauty, 512, 512)[3] == 255, "solid where the cube is")
        #expect(pixel(last.depth, 3, 3)[3] == 255, "the depth pass is always solid")
    }

    @Test func nothingToRenderWithoutAScene() throws {
        let (model, _) = try setUp()
        model.close()
        model.render()
        #expect(model.lastRender == nil && model.notice == "Open a scene to render it.")
    }
}
