import AetherGraph
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ModelCore
@testable import ModelUI

@MainActor
struct TracerTests {
    private func setUp() throws -> (ModelWorkspaceModel, ProjectGraph) {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = ProjectGraph(folder: root)
        let model = ModelWorkspaceModel(folder: root.appending(path: "Models", directoryHint: .isDirectory))
        model.project = project
        model.newScene(named: "Room")
        return (model, project)
    }

    /// The average colour of a region of a picture, from its top left, RGBA.
    private func average(_ image: CGImage, _ rect: CGRect) -> [Double] {
        guard let crop = image.cropping(to: rect) else { return [0, 0, 0, 0] }
        var out = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return out.map(Double.init)
    }

    @Test func theTracerCompilesWithEveryKindOfMaterial() throws {
        let (model, _) = try setUp()
        for pattern in LayerPattern.allCases { model.addLayer(pattern) }
        let shaders: [SceneShader?] = model.document!.state.shaders + [nil]
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: SceneShaderSource.tracer(shaders), options: nil)
        #expect(library.makeFunction(name: "trace") != nil && library.makeFunction(name: "finish") != nil)
        let (values, starts) = SceneShaderSource.tracerConstants(shaders)
        #expect(starts.count == shaders.count + 1 && starts[0] == 0 && Int(starts[1]) == 1)
        #expect(values.count >= 1 + SceneShaderSource.constants(of: shaders[0]).count)
    }

    @Test func aPathTracedRenderSeesTheCubeItsColourAndTheLightBouncedOffIt() async throws {
        let (model, project) = try setUp()
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { return }
        model.frameAll()
        model.addLayer(.solid)
        model.editStack("Red") { stack in
            stack.layers[0].amount = 1
            stack.layers[0].surface = SceneSurface(color: [0.8, 0.05, 0.05], metallic: 0, roughness: 0.6)
        }
        model.renderSize = .square
        model.renderEngine = .traced
        model.renderSamples = 32
        model.render()
        #expect(model.renderProgress != nil, "under way")
        await model.renderFinished()
        let last = try #require(model.lastRender, "\(model.notice ?? "no render")")
        #expect(model.renderProgress == nil)
        let cube = average(last.beauty, CGRect(x: 480, y: 480, width: 64, height: 64))
        #expect(cube[0] > cube[2] + 40, "the cube is red: \(cube)")
        let sky = average(last.beauty, CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(sky[0] < 20, "the ground behind: \(sky)")
        #expect(last.depth.width == 1024, "the depth pass, from the quick render")

        // The floor right by the red cube takes some of its red; the floor
        // far off doesn't.
        model.renderEngine = .quick
        model.render()
        let quick = try #require(model.lastRender)
        let nearTraced = average(last.beauty, CGRect(x: 400, y: 900, width: 220, height: 60))
        let nearQuick = average(quick.beauty, CGRect(x: 400, y: 900, width: 220, height: 60))
        #expect(nearTraced[0] - nearTraced[2] > nearQuick[0] - nearQuick[2], "red bounced on to the floor: \(nearTraced) vs \(nearQuick)")
        _ = project
    }

    @Test func aPathTracedRenderStopsWhereItIsAndKeepsWhatItHas() async throws {
        let (model, project) = try setUp()
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { return }
        model.frameAll()
        model.renderSize = .square
        model.renderEngine = .traced
        model.renderSamples = 2048
        model.render()
        model.stopRender()
        await model.renderFinished()
        let last = try #require(model.lastRender)
        #expect(average(last.beauty, CGRect(x: 480, y: 480, width: 64, height: 64))[0] > 60, "the cube, from the samples it had")
        for _ in 0..<200 where project.assets.filter({ $0.source == .model }).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(project.assets.filter { $0.source == .model }.count == 2, "published as any render is")
    }
}
