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

    /// A picture's pixels, RGBA, row by row from the top.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    /// How grainy a region is: the mean difference between a pixel and the
    /// one to its right, over red, green and blue.
    private func grain(_ image: CGImage, _ rect: CGRect) -> Double {
        let p = pixels(image)
        var total = 0.0, count = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) - 1 {
                for c in 0..<3 {
                    let i = (y * image.width + x) * 4 + c
                    total += abs(Double(p[i]) - Double(p[i + 4]))
                    count += 1
                }
            }
        }
        return total / count
    }

    /// The sharpest step across a row band: the most red changes from one
    /// pixel to the next, averaged down `rows`.
    private func sharpestStep(_ image: CGImage, rows: Range<Int>) -> Double {
        let p = pixels(image)
        var profile = [Double](repeating: 0, count: image.width)
        for y in rows {
            for x in 0..<image.width { profile[x] += Double(p[(y * image.width + x) * 4]) / Double(rows.count) }
        }
        return zip(profile, profile.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    @Test func theTracerCompilesWithEveryKindOfMaterial() throws {
        let (model, _) = try setUp()
        for pattern in LayerPattern.allCases { model.addLayer(pattern) }
        let shaders: [SceneShader?] = model.document!.state.shaders + [nil]
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: SceneShaderSource.tracer(shaders), options: nil)
        for name in ["trace", "finish", "prepare", "smooth", "finishSmoothed"] {
            #expect(library.makeFunction(name: name) != nil, "\(name)")
        }
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

    @Test func theDenoiserSmoothsTheGrainAndKeepsTheEdges() async throws {
        let (model, _) = try setUp()
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
        func traced(_ samples: Int, denoise: Bool) async throws -> CGImage {
            model.renderSamples = samples
            model.renderDenoise = denoise
            model.render()
            await model.renderFinished()
            return try #require(model.lastRender, "\(model.notice ?? "no render")").beauty
        }
        let raw = try await traced(16, denoise: false)
        let smooth = try await traced(16, denoise: true)
        let reference = try await traced(512, denoise: false)

        // The floor by the cube, in the soft light bounced off it.
        let floor = CGRect(x: 400, y: 900, width: 220, height: 60)
        let (rawGrain, smoothGrain, referenceGrain) = (grain(raw, floor), grain(smooth, floor), grain(reference, floor))
        #expect(smoothGrain < rawGrain * 0.4, "smoother than its samples: \(smoothGrain) vs \(rawGrain)")
        #expect(smoothGrain < referenceGrain * 1.5, "as smooth as 32 times the samples: \(smoothGrain) vs \(referenceGrain)")
        // Not darker or lighter, nor tinted: the same light, smoothed.
        let (s, r) = (average(smooth, floor), average(reference, floor))
        for c in 0..<3 { #expect(abs(s[c] - r[c]) < 8, "the floor's colour kept: \(s) vs \(r)") }
        let (sc, rc) = (average(smooth, CGRect(x: 480, y: 480, width: 64, height: 64)), average(reference, CGRect(x: 480, y: 480, width: 64, height: 64)))
        for c in 0..<3 { #expect(abs(sc[c] - rc[c]) < 8, "the cube's colour kept: \(sc) vs \(rc)") }
        // The cube's sides stay as sharp as the reference's.
        let band = 500..<524
        #expect(sharpestStep(smooth, rows: band) > sharpestStep(reference, rows: band) * 0.7, "the edge kept: \(sharpestStep(smooth, rows: band)) vs \(sharpestStep(reference, rows: band))")
    }

    /// The cube's faces lie on its checker's cell edges: the tracer finds
    /// the point on a face as the raster does, so they don't flicker.
    @Test func aCheckerOnTheCubesFacesDoesntFlicker() async throws {
        let (model, _) = try setUp()
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { return }
        model.frameSelected()
        model.addLayer(.checker)
        model.renderSize = .square
        model.render()
        let quick = try #require(model.lastRender).beauty
        model.renderEngine = .traced
        model.renderSamples = 64
        model.render()
        await model.renderFinished()
        let traced = try #require(model.lastRender, "\(model.notice ?? "no render")").beauty
        let cube = CGRect(x: 300, y: 300, width: 424, height: 424)
        #expect(grain(traced, cube) < grain(quick, cube) * 1.3, "no grain beyond the checker's own edges: \(grain(traced, cube)) vs \(grain(quick, cube))")
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
