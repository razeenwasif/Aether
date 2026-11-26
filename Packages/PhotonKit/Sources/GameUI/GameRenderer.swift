import CoreGraphics
import Foundation
import GameCore
import Metal
import os
import QuartzCore
import simd

/// The stage's renderer, on Metal: a list of sprites drawn lit and finished.
/// It knows nothing of planes or parallax: the layout (`GameScene.layout`)
/// says what's drawn where, and a camera's matrix how the world lands on
/// the target, so other projections draw with it unchanged (plan §9b).
///
/// A frame is two steps. The picture: sprites in runs of one texture, one
/// blend and one normal map, into a picture of its own (half floats, so
/// light can pass white), at the target's size or, for pixel art in Play,
/// at the game's own. Then the finish, onto the target: the picture's
/// bright part blurred at half size and laid back (bloom), a grade, a
/// vignette, and the picture scaled up (sampled nearest for pixel art).
@MainActor
final class GameRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var sprites: [String: MTLRenderPipelineState] = [:]
    private var meshes: [String: MTLRenderPipelineState] = [:]
    private let bright: MTLRenderPipelineState
    private let blur: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let smooth: MTLSamplerState
    private let sharp: MTLSamplerState
    private let flat: MTLTexture
    private let glow: MTLTexture
    private let black: MTLTexture
    /// Each image on the GPU (by its key, and whether it has smaller copies),
    /// with the picture it was made from, so a picture read again is
    /// uploaded again.
    private var textures: [String: (image: CGImage, texture: MTLTexture)] = [:]
    private var targets: (size: CGSize, picture: MTLTexture, a: MTLTexture, b: MTLTexture)?

    static let pictureFormat = MTLPixelFormat.rgba16Float
    static let targetFormat = MTLPixelFormat.bgra8Unorm
    static let log = OSLog(subsystem: "dev.razeen.photon", category: "render")

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: GameRenderSource.source, options: nil) else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, blend: String? = nil) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let colour = d.colorAttachments[0]!
            colour.pixelFormat = format
            if let blend {
                // Over premultiplied colour, as Proton's blends were.
                colour.isBlendingEnabled = true
                colour.alphaBlendOperation = .add
                colour.sourceAlphaBlendFactor = .one
                colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                switch blend {
                case "add": (colour.sourceRGBBlendFactor, colour.destinationRGBBlendFactor) = (.one, .one)
                case "multiply": (colour.sourceRGBBlendFactor, colour.destinationRGBBlendFactor) = (.destinationColor, .oneMinusSourceAlpha)
                case "screen": (colour.sourceRGBBlendFactor, colour.destinationRGBBlendFactor) = (.one, .oneMinusSourceColor)
                default: (colour.sourceRGBBlendFactor, colour.destinationRGBBlendFactor) = (.one, .oneMinusSourceAlpha)
                }
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        for blend in ["normal", "add", "multiply", "screen"] {
            guard let made = pipeline("spriteVertex", "spriteFragment", Self.pictureFormat, blend: blend),
                  let mesh = pipeline("meshVertex", "spriteFragment", Self.pictureFormat, blend: blend) else { return nil }
            sprites[blend] = made
            meshes[blend] = mesh
        }
        guard let bright = pipeline("fullVertex", "brightFragment", Self.pictureFormat),
              let blur = pipeline("fullVertex", "blurFragment", Self.pictureFormat),
              let composite = pipeline("fullVertex", "compositeFragment", Self.targetFormat) else { return nil }
        self.bright = bright
        self.blur = blur
        self.composite = composite
        func sampler(_ filter: MTLSamplerMinMagFilter, mips: Bool) -> MTLSamplerState? {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.mipFilter = mips ? .linear : .notMipmapped
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: d)
        }
        guard let smooth = sampler(.linear, mips: true), let sharp = sampler(.nearest, mips: false) else { return nil }
        self.smooth = smooth
        self.sharp = sharp
        func made(_ n: Int, _ pixel: (Int, Int) -> [UInt8]) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: false)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            var bytes: [UInt8] = []
            for y in 0..<n { for x in 0..<n { bytes += pixel(x, y) } }
            t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: bytes, bytesPerRow: n * 4)
            return t
        }
        // A surface facing straight out, for art with no normal map.
        guard let flat = made(1, { _, _ in [128, 128, 255, 255] }),
              let black = made(1, { _, _ in [0, 0, 0, 255] }),
              // A light's glow: white, falling off from the middle, premultiplied.
              let glow = made(64, { x, y in
                  let r = hypot(Double(x) + 0.5 - 32, Double(y) + 0.5 - 32) / 32
                  let a = UInt8((255 * pow(max(0, 1 - r), 2)).rounded())
                  return [a, a, a, a]
              }) else { return nil }
        self.flat = flat
        self.black = black
        self.glow = glow
    }

    /// What a frame is: the sprites and their light, the camera, what's
    /// behind everything, and the finish (none in the editor unless asked).
    struct Job {
        var sprites: [GameSprite]
        var lighting = GameLighting()
        var camera: GameCamera
        var background = SIMD3<Float>(0.028, 0.031, 0.04)
        var post: GamePost?
        /// Pixel art: sampled nearest.
        var pixelArt = false
        /// The picture's own size, when it's drawn smaller than the target
        /// and scaled up (pixel art in Play); the target's when nil.
        var pictureSize: CGSize?
    }

    /// A frame encoded onto `target`.
    func encode(_ job: Job, images: GameImages, into target: MTLTexture, on buffer: MTLCommandBuffer) {
        let size = job.pictureSize ?? CGSize(width: target.width, height: target.height)
        guard let t = targetsFor(size) else { return }
        drawPicture(job, images: images, into: t.picture, on: buffer)
        finish(job, t, images: images, into: target, on: buffer)
    }

    /// A frame drawn onto a drawable and shown.
    func draw(_ job: Job, images: GameImages, into drawable: CAMetalDrawable, presentsWithTransaction: Bool) {
        let signpost = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "game frame", signpostID: signpost)
        defer { os_signpost(.end, log: Self.log, name: "game frame", signpostID: signpost) }
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(job, images: images, into: drawable.texture, on: buffer)
        if presentsWithTransaction {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }

    /// A frame drawn offscreen, as a picture: for the tests, and for a still
    /// of the stage.
    func picture(_ job: Job, images: GameImages, width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.targetFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let buffer = queue.makeCommandBuffer() else { return nil }
        encode(job, images: images, into: target, on: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: The picture

    private struct Instance {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var tint: SIMD4<Float>
        var misc: SIMD4<Float>
    }

    private struct MeshPoint {
        var world: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var tint: SIMD4<Float>
        var misc: SIMD4<Float>
    }

    private struct Frame {
        var matrix: simd_float4x4
        var ambient: SIMD4<Float>
        var lights: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    private func frame(_ job: Job, size: CGSize) -> Frame {
        var packed = [SIMD4<Float>](repeating: .zero, count: GameRenderSource.lights * 2)
        let lamps = job.lighting.lamps.prefix(GameRenderSource.lights)
        for (i, l) in lamps.enumerated() {
            packed[i * 2] = SIMD4(Float(l.at.x), Float(l.at.y), Float(l.radius), Float(l.height))
            packed[i * 2 + 1] = SIMD4(l.color, 0)
        }
        var f = Frame(matrix: job.camera.matrix(target: size), ambient: SIMD4(job.lighting.ambient, Float(lamps.count)),
                      lights: (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
                               .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero))
        withUnsafeMutableBytes(of: &f.lights) { raw in
            packed.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return f
    }

    private func drawPicture(_ job: Job, images: GameImages, into picture: MTLTexture, on buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = picture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(job.background.x), green: Double(job.background.y), blue: Double(job.background.z), alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard !job.sprites.isEmpty else { return }
        let instances = job.sprites.map { s -> Instance in
            let (u0, u1) = s.flip ? (s.uv.maxX, s.uv.minX) : (s.uv.minX, s.uv.maxX)
            return Instance(rect: SIMD4(Float(s.rect.minX), Float(s.rect.minY), Float(s.rect.width), Float(s.rect.height)),
                            uv: SIMD4(Float(u0), Float(s.uv.minY), Float(u1), Float(s.uv.maxY)),
                            tint: s.tint,
                            misc: SIMD4(Float(s.opacity), Float(s.rot * .pi / 180), s.lit ? 1 : 0, s.flip ? 1 : 0))
        }
        guard let vertices = device.makeBuffer(bytes: instances, length: MemoryLayout<Instance>.stride * instances.count, options: .storageModeShared) else { return }
        // Skeletons' parts, their triangles laid out point by point, each
        // part's run of them by where it starts.
        var points: [MeshPoint] = []
        var runs: [Int: Range<Int>] = [:]
        for (i, s) in job.sprites.enumerated() {
            guard let mesh = s.mesh else { continue }
            let from = points.count
            let misc = SIMD4<Float>(Float(s.opacity), 0, s.lit ? 1 : 0, 0)
            for index in mesh.indices where Int(index) < mesh.points.count && Int(index) < mesh.uv.count {
                points.append(MeshPoint(world: mesh.points[Int(index)], uv: mesh.uv[Int(index)], color: mesh.color, tint: s.tint, misc: misc))
            }
            runs[i] = from..<points.count
        }
        let meshBuffer = points.isEmpty ? nil : device.makeBuffer(bytes: points, length: MemoryLayout<MeshPoint>.stride * points.count, options: .storageModeShared)
        var f = frame(job, size: CGSize(width: picture.width, height: picture.height))
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentSamplerState(job.pixelArt ? sharp : smooth, index: 0)
        // In runs of one texture, one blend and one normal map, in the
        // layout's order.
        var start = 0
        let all = job.sprites
        while start < all.count {
            let first = all[start]
            if first.mesh != nil {
                // A skeleton's part, alone.
                if let run = runs[start], !run.isEmpty, let meshBuffer, let pipeline = meshes[first.blend] ?? meshes["normal"],
                   let art = texture(first.key, images: images, mipmapped: !job.pixelArt) {
                    var mapped: Float = 0
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
                    encoder.setFragmentTexture(art, index: 0)
                    encoder.setFragmentTexture(flat, index: 1)
                    encoder.setFragmentBytes(&mapped, length: 4, index: 2)
                    encoder.drawPrimitives(type: .triangle, vertexStart: run.lowerBound, vertexCount: run.count)
                    encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                }
                start += 1
                continue
            }
            var end = start + 1
            while end < all.count, all[end].mesh == nil, all[end].key == first.key, all[end].blend == first.blend, all[end].normal == first.normal { end += 1 }
            let art = first.key == GameSprite.glow ? glow : texture(first.key, images: images, mipmapped: !job.pixelArt)
            if let art, let pipeline = sprites[first.blend] ?? sprites["normal"] {
                let normal = first.normal.flatMap { texture($0, images: images, mipmapped: !job.pixelArt) }
                var mapped: Float = normal == nil ? 0 : 1
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(art, index: 0)
                encoder.setFragmentTexture(normal ?? flat, index: 1)
                encoder.setFragmentBytes(&mapped, length: 4, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: end - start, baseInstance: start)
            }
            start = end
        }
    }

    // MARK: The finish

    private struct Finish {
        var bloom: Float
        var vignette: Float
        var lut: Float
        var nearest: Float
    }

    private func finish(_ job: Job, _ t: (size: CGSize, picture: MTLTexture, a: MTLTexture, b: MTLTexture), images: GameImages, into target: MTLTexture, on buffer: MTLCommandBuffer) {
        let post = job.post
        func pass(_ pipeline: MTLRenderPipelineState, into texture: MTLTexture, from: MTLTexture, _ setup: (MTLRenderCommandEncoder) -> Void = { _ in }) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = texture
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: d) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(from, index: 0)
            encoder.setFragmentSamplerState(smooth, index: 0)
            setup(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        let blooms = (post?.bloom ?? 0) > 0
        if blooms {
            pass(bright, into: t.a, from: t.picture)
            var across = SIMD2<Float>(1 / Float(t.a.width), 0)
            pass(blur, into: t.b, from: t.a) { $0.setFragmentBytes(&across, length: 8, index: 0) }
            var down = SIMD2<Float>(0, 1 / Float(t.a.height))
            pass(blur, into: t.a, from: t.b) { $0.setFragmentBytes(&down, length: 8, index: 0) }
        }
        let grade = post?.grade.flatMap { gradeTexture($0, images: images) }
        var f = Finish(bloom: blooms ? Float(post?.bloom ?? 0) : 0, vignette: Float(post?.vignette ?? 0),
                       lut: grade.map { Float($0.height) } ?? 0, nearest: job.pixelArt && job.pictureSize != nil ? 1 : 0)
        pass(composite, into: target, from: t.picture) {
            $0.setFragmentTexture(blooms ? t.a : self.black, index: 1)
            $0.setFragmentTexture(grade ?? self.flat, index: 2)
            $0.setFragmentBytes(&f, length: MemoryLayout<Finish>.stride, index: 0)
        }
    }

    private func targetsFor(_ size: CGSize) -> (size: CGSize, picture: MTLTexture, a: MTLTexture, b: MTLTexture)? {
        if let targets, targets.size == size { return targets }
        func target(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pictureFormat, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let (w, h) = (Int(size.width), Int(size.height))
        guard let picture = target(w, h), let a = target(w / 2, h / 2), let b = target(w / 2, h / 2) else { return nil }
        targets = (size, picture, a, b)
        return targets
    }

    // MARK: Textures

    /// An image on the GPU, premultiplied, with smaller copies for painted
    /// art zoomed out.
    func texture(_ key: String, images: GameImages, mipmapped: Bool = true) -> MTLTexture? {
        guard let image = images.image(key) else { return nil }
        let slot = mipmapped ? key : "\(key)#flat"
        if let hit = textures[slot], hit.image === image { return hit.texture }
        guard let made = upload(image, mipmapped: mipmapped) else { return nil }
        textures[slot] = (image, made)
        return made
    }

    /// A grade's table: n² wide and n tall, smooth between its cells.
    private func gradeTexture(_ key: String, images: GameImages) -> MTLTexture? {
        guard let t = texture(key, images: images, mipmapped: false), t.width == t.height * t.height else { return nil }
        return t
    }

    private func upload(_ image: CGImage, mipmapped: Bool) -> MTLTexture? {
        let (w, h) = (image.width, image.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: mipmapped)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        if mipmapped, texture.mipmapLevelCount > 1, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }
}
