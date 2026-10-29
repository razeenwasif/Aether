import MetalKit
import ModelCore
import simd

/// Draws a scene: each mesh with its material run per pixel, everything
/// without a surface as a stand-in drawn in lines (a cross for an empty, a
/// burst for a light, a frustum for a camera, a box for a mesh that isn't
/// here), and the floor grid. Proton's `gl.js` and `viewport.js`, on Metal.
/// In Edit mode the object being edited draws its own mesh, before its
/// modifiers, with its edges, its corners and what's chosen over it.
/// Drawn only when something changes, so a still scene costs nothing.
@MainActor
final class ModelRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lines: MTLRenderPipelineState
    private let overlayLines: MTLRenderPipelineState
    private let overlayPoints: MTLRenderPipelineState
    private let solid: MTLDepthStencilState
    private let over: MTLDepthStencilState
    private var surfaces: [String: MTLRenderPipelineState] = [:]
    private var buffers: [String: Held] = [:]
    private let inFlight = DispatchSemaphore(value: 3)
    weak var model: ModelWorkspaceModel?

    private struct Held {
        var shape: String
        var positions: MTLBuffer
        var normals: MTLBuffer
        var indices: MTLBuffer
        var count: Int
        var closed: Bool
    }

    private struct FrameUniforms {
        var proj: simd_float4x4
        var light: SIMD3<Float>
        var tint: SIMD3<Float>
    }

    private struct ObjectUniforms {
        var modelView: simd_float4x4
        var normal: simd_float3x3
        var picked: Float
    }

    private struct LineVertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    private struct OverlayUniforms {
        var view: simd_float4x4
        var proj: simd_float4x4
        var size: Float
    }

    static let sampleCount = 4
    /// The key light, in the world: a shading cue, not a light in the scene.
    private static let key = simd_normalize(SIMD3<Float>(-0.4, 0.82, 0.55))
    /// Selection: Velvet Obsidian's ice.
    private static let ice = SIMD3<Float>(0.616, 0.706, 1.0)

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: SceneShaderSource.surface(nil), options: nil)
            let line = MTLRenderPipelineDescriptor()
            line.vertexFunction = library.makeFunction(name: "lineVertex")
            line.fragmentFunction = library.makeFunction(name: "lineFragment")
            line.colorAttachments[0].pixelFormat = .bgra8Unorm
            line.colorAttachments[0].isBlendingEnabled = true
            line.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            line.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            line.depthAttachmentPixelFormat = .depth32Float
            line.rasterSampleCount = Self.sampleCount
            let v = MTLVertexDescriptor()
            v.attributes[0].format = .float3
            v.attributes[0].offset = 0
            v.attributes[0].bufferIndex = 0
            v.attributes[1].format = .float4
            v.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
            v.attributes[1].bufferIndex = 0
            v.layouts[0].stride = MemoryLayout<LineVertex>.stride
            line.vertexDescriptor = v
            lines = try device.makeRenderPipelineState(descriptor: line)
            line.vertexFunction = library.makeFunction(name: "overlayVertex")
            overlayLines = try device.makeRenderPipelineState(descriptor: line)
            line.vertexFunction = library.makeFunction(name: "pointVertex")
            line.fragmentFunction = library.makeFunction(name: "pointFragment")
            overlayPoints = try device.makeRenderPipelineState(descriptor: line)
        } catch {
            return nil
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let solid = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.solid = solid
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = false
        guard let over = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.over = over
        super.init()
    }

    /// A pipeline for a mesh: positions in buffer 0, normals in buffer 3.
    private static func surfaceDescriptor(_ library: MTLLibrary, fragment: String) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "surfaceVertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        d.rasterSampleCount = Self.sampleCount
        let v = MTLVertexDescriptor()
        v.attributes[0].format = .float3
        v.attributes[0].bufferIndex = 0
        v.attributes[1].format = .float3
        v.attributes[1].bufferIndex = 3
        v.layouts[0].stride = 12
        v.layouts[3].stride = 12
        d.vertexDescriptor = v
        return d
    }

    /// The pipeline for a material's program, compiled the first time.
    private func surface(_ shader: SceneShader?) -> MTLRenderPipelineState? {
        let key = SceneShaderSource.key(shader)
        if let made = surfaces[key] { return made }
        do {
            let library = try device.makeLibrary(source: SceneShaderSource.surface(shader), options: nil)
            let made = try device.makeRenderPipelineState(descriptor: Self.surfaceDescriptor(library, fragment: "surfaceFragment"))
            surfaces[key] = made
            return made
        } catch {
            // A material that won't compile draws in the plain grey.
            return key == "plain" ? nil : surface(nil)
        }
    }

    /// An object's buffers, made again only when its mesh or stack changes.
    private func held(_ id: String, _ shape: String, _ mesh: SceneMeshData) -> Held? {
        if let kept = buffers[id], kept.shape == shape { return kept }
        guard !mesh.triangles.isEmpty,
              let positions = device.makeBuffer(bytes: mesh.positions, length: mesh.positions.count * 4, options: .storageModeShared),
              let indices = device.makeBuffer(bytes: mesh.triangles, length: mesh.triangles.count * 4, options: .storageModeShared) else { return nil }
        // No normals: zeros, and the fragment stage works out the face's own.
        let normals = mesh.normals.count == mesh.positions.count
            ? device.makeBuffer(bytes: mesh.normals, length: mesh.normals.count * 4, options: .storageModeShared)
            : device.makeBuffer(length: mesh.positions.count * 4, options: .storageModeShared)
        guard let normals else { return nil }
        let made = Held(shape: shape, positions: positions, normals: normals, indices: indices, count: mesh.triangles.count, closed: mesh.closed)
        buffers[id] = made
        return made
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        inFlight.wait()
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let size = view.bounds.size
        let nodes = model.document?.state.objects ?? []
        let worlds = SceneMath.worlds(nodes)
        let viewMatrix = model.camera.view
        let span = boxSpan(model)
        let near = max(0.01, model.camera.distance * 0.002)
        let far = max(near * 1000, model.camera.distance * 4 + span * 4)
        let proj = SceneMath.perspective(aspect: Float(size.width / max(size.height, 1)), near: near, far: far)
        let light = viewMatrix * SIMD4(Self.key, 0)
        var frame = FrameUniforms(proj: proj, light: SIMD3(light.x, light.y, light.z), tint: Self.ice)
        let shaders = Dictionary((model.document?.state.shaders ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        encoder.setDepthStencilState(solid)
        var triangles = 0
        var stand: [LineVertex] = []
        var overlay: (world: simd_float4x4, edit: MeshEditSession)?
        for node in nodes {
            let world = worlds[node.id] ?? matrix_identity_float4x4
            let picked = node.id == model.selected
            let edit = model.editing.flatMap { $0.nodeID == node.id ? $0 : nil }
            if let edit { overlay = (world, edit) }
            let mesh = edit.map(cageMesh) ?? (node.kind == "mesh" && !node.mesh.isEmpty ? model.document?.mesh(for: node) : nil)
            let shape = edit.map { "edit:\($0.shapeRevision)" } ?? node.shape
            let shader = node.material.isEmpty ? nil : shaders[node.material]
            guard let mesh, let held = held(node.id, shape, mesh), let pipeline = surface(shader) else {
                standIn(for: node, bounds: mesh?.bounds, world: world, picked: picked, into: &stand)
                continue
            }
            let modelView = viewMatrix * world
            let upper = simd_float3x3(SIMD3(modelView.columns.0.x, modelView.columns.0.y, modelView.columns.0.z),
                                      SIMD3(modelView.columns.1.x, modelView.columns.1.y, modelView.columns.1.z),
                                      SIMD3(modelView.columns.2.x, modelView.columns.2.y, modelView.columns.2.z))
            var object = ObjectUniforms(modelView: modelView, normal: upper.inverse.transpose, picked: picked && edit == nil ? 1 : 0)
            encoder.setRenderPipelineState(pipeline)
            // Backs are culled only on a solid: a sheet would vanish edge-on.
            encoder.setCullMode(held.closed ? .back : .none)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(held.positions, offset: 0, index: 0)
            encoder.setVertexBuffer(held.normals, offset: 0, index: 3)
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setVertexBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            // A program's constants (at most 4 KB: 256 of them, far past any
            // stack's).
            var constants = Array(SceneShaderSource.constants(of: shader).prefix(256))
            encoder.setFragmentBytes(&constants, length: constants.count * MemoryLayout<SIMD4<Float>>.stride, index: 4)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: held.count, indexType: .uint32, indexBuffer: held.indices, indexBufferOffset: 0)
            triangles += held.count / 3
        }
        // Buffers of objects gone go too.
        let ids = Set(nodes.map(\.id))
        buffers = buffers.filter { ids.contains($0.key) }

        var all = grid() + stand
        if !all.isEmpty, let buffer = device.makeBuffer(bytes: &all, length: all.count * MemoryLayout<LineVertex>.stride, options: .storageModeShared) {
            var viewProj = proj * viewMatrix
            encoder.setCullMode(.none)
            encoder.setRenderPipelineState(lines)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewProj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: all.count)
        }
        if let overlay {
            let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
            drawOverlay(overlay.edit, world: overlay.world, view: viewMatrix, proj: proj, scale: scale, encoder: encoder)
        }
        encoder.endEncoding()
        commands.present(drawable)
        let (count, drawn) = (nodes.count, triangles)
        commands.addCompletedHandler { [weak self, inFlight] buffer in
            inFlight.signal()
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Task { @MainActor in
                self?.model?.stats = ModelStats(triangles: drawn, objects: count, gpuMilliseconds: ms)
            }
        }
        commands.commit()
    }

    // MARK: Render

    /// A render's two pictures: the scene as shaded, and its depth.
    struct Pictures {
        var beauty: CGImage
        var depth: CGImage
    }

    struct RenderFailure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    private var depthPipeline: MTLRenderPipelineState?

    /// The scene from the camera, `width` by `height`: drawn at twice that
    /// with 4× multisampling and scaled down, without the grid, the stand-ins,
    /// Edit mode's cage or the chosen object's tint. Then again for depth,
    /// near white and far black across what the scene spans in front of the
    /// camera.
    func render(width: Int, height: Int, transparent: Bool) throws -> Pictures {
        guard let model, let document = model.document else { throw RenderFailure(reason: "open a scene to render") }
        let scale = min(2, 8192 / max(width, height))
        let (w, h) = (width * max(scale, 1), height * max(scale, 1))
        let nodes = document.state.objects
        let worlds = SceneMath.worlds(nodes)
        let view = model.camera.view
        // What's in front of the camera, for the depth pass and the planes.
        let depths = model.boxes().flatMap(\.corners).map { -(view * SIMD4($0, 1)).z }.filter { $0 > 0 }
        let nearest = max(0.01, (depths.min() ?? 0.1) * 0.98)
        let farthest = max(nearest * 1.01, (depths.max() ?? 10) * 1.02)
        let proj = SceneMath.perspective(aspect: Float(width) / Float(max(height, 1)), near: max(0.005, nearest * 0.5), far: farthest * 1.5)
        let light = view * SIMD4(Self.key, 0)
        var frame = FrameUniforms(proj: proj, light: SIMD3(light.x, light.y, light.z), tint: Self.ice)
        let shaders = Dictionary(document.state.shaders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if depthPipeline == nil {
            let library = try device.makeLibrary(source: SceneShaderSource.surface(nil), options: nil)
            depthPipeline = try device.makeRenderPipelineState(descriptor: Self.surfaceDescriptor(library, fragment: "depthFragment"))
        }
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            d.usage = usage
            d.storageMode = storage
            guard let made = device.makeTexture(descriptor: d) else { throw RenderFailure(reason: "the GPU couldn’t make a \(w) × \(h) picture") }
            return made
        }
        let color = try texture(.bgra8Unorm, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        let depthTarget = try texture(.depth32Float, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        let readable: MTLStorageMode = device.hasUnifiedMemory ? .shared : .managed
        let beauty = try texture(.bgra8Unorm, samples: 1, usage: .renderTarget, storage: readable)
        let deep = try texture(.bgra8Unorm, samples: 1, usage: .renderTarget, storage: readable)

        guard let commands = queue.makeCommandBuffer() else { throw RenderFailure(reason: "the GPU is busy") }
        for (resolve, isDepth) in [(beauty, false), (deep, true)] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.colorAttachments[0].clearColor = isDepth ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                : transparent ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) : MTLClearColor(red: 0.028, green: 0.031, blue: 0.04, alpha: 1)
            pass.depthAttachment.texture = depthTarget
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw RenderFailure(reason: "the GPU is busy") }
            encoder.setDepthStencilState(solid)
            encoder.setFrontFacing(.counterClockwise)
            var range = SIMD2<Float>(nearest, farthest)
            for node in nodes where node.kind == "mesh" && !node.mesh.isEmpty {
                let shader = node.material.isEmpty ? nil : shaders[node.material]
                let mesh = document.mesh(for: node)
                guard let held = held(node.id, node.shape, mesh), let pipeline = isDepth ? depthPipeline : surface(shader) else { continue }
                let modelView = view * (worlds[node.id] ?? matrix_identity_float4x4)
                let upper = simd_float3x3(SIMD3(modelView.columns.0.x, modelView.columns.0.y, modelView.columns.0.z),
                                          SIMD3(modelView.columns.1.x, modelView.columns.1.y, modelView.columns.1.z),
                                          SIMD3(modelView.columns.2.x, modelView.columns.2.y, modelView.columns.2.z))
                var object = ObjectUniforms(modelView: modelView, normal: upper.inverse.transpose, picked: 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setCullMode(held.closed ? .back : .none)
                encoder.setVertexBuffer(held.positions, offset: 0, index: 0)
                encoder.setVertexBuffer(held.normals, offset: 0, index: 3)
                encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setVertexBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
                var constants = Array(SceneShaderSource.constants(of: shader).prefix(256))
                encoder.setFragmentBytes(&constants, length: constants.count * MemoryLayout<SIMD4<Float>>.stride, index: 4)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: held.count, indexType: .uint32, indexBuffer: held.indices, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }
        if readable == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: beauty)
            blit.synchronize(resource: deep)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw RenderFailure(reason: error.localizedDescription) }
        return Pictures(beauty: try Self.image(beauty, width: width, height: height, opaque: !transparent),
                        depth: try Self.image(deep, width: width, height: height, opaque: true))
    }

    /// A rendered texture as a picture, scaled down to `width` by `height`.
    private static func image(_ texture: MTLTexture, width: Int, height: Int, opaque: Bool) throws -> CGImage {
        let (w, h) = (texture.width, texture.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst).rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw RenderFailure(reason: "couldn’t make the picture")
        }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { throw RenderFailure(reason: "couldn’t make the picture") }
        return small
    }

    /// How far the scene reaches from the camera's target, for the far plane.
    private func boxSpan(_ model: ModelWorkspaceModel) -> Float {
        model.boxes().flatMap(\.corners).map { simd_length($0 - model.camera.target) }.max() ?? 10
    }

    // MARK: Edit mode

    /// The mesh being edited, as a mesh to draw: faceted, before modifiers.
    private func cageMesh(_ edit: MeshEditSession) -> SceneMeshData {
        let c = edit.cage
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for v in 0 ..< c.vertexCount {
            lo = simd_min(lo, c.position(UInt32(v)))
            hi = simd_max(hi, c.position(UInt32(v)))
        }
        return SceneMeshData(positions: c.positions, normals: [], triangles: c.triangles, bounds: c.vertexCount > 0 ? [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z] : [], closed: c.closed, problem: nil)
    }

    /// The faces chosen, filled in ice; every edge, the chosen ones in ice;
    /// and in Vertices, every corner.
    private func drawOverlay(_ edit: MeshEditSession, world: simd_float4x4, view: simd_float4x4, proj: simd_float4x4, scale: Float, encoder: MTLRenderCommandEncoder) {
        let c = edit.cage
        let at: [SIMD3<Float>] = (0 ..< c.vertexCount).map { v in
            let p = world * SIMD4(c.position(UInt32(v)), 1)
            return SIMD3(p.x, p.y, p.z)
        }
        // Chosen: a deep blue, since a line is one pixel and a pale one is
        // lost on the light grey surface.
        let ice = SIMD4<Float>(0.18, 0.42, 1.0, 1)
        // Dark on the light grey surface, as a wire must be to read on it.
        let faint = SIMD4<Float>(0.04, 0.05, 0.07, 0.9)
        let corners = Set(edit.chosenVertices)
        let shownFaces: Set<UInt32> = edit.part == .faces ? edit.faces : []
        let shownEdges: Set<MeshEdge> = switch edit.part {
        case .edges: edit.edges
        case .faces: Set(edit.faces.flatMap { c.edges(of: $0) })
        case .vertices: Set(c.edges.filter { corners.contains($0.a) && corners.contains($0.b) })
        }
        var fill: [LineVertex] = []
        for i in stride(from: 0, to: c.triangles.count - 2, by: 3) where shownFaces.contains(c.triangleFaces[i / 3]) {
            for k in 0 ..< 3 { fill.append(LineVertex(position: at[Int(c.triangles[i + k])], color: SIMD4(0.42, 0.56, 1.0, 0.55))) }
        }
        var wire: [LineVertex] = []
        for e in c.edges {
            let color = shownEdges.contains(e) ? ice : faint
            wire += [LineVertex(position: at[Int(e.a)], color: color), LineVertex(position: at[Int(e.b)], color: color)]
        }
        encoder.setDepthStencilState(over)
        encoder.setCullMode(.none)
        var uniforms = OverlayUniforms(view: view, proj: proj, size: 0)
        func draw(_ vertices: [LineVertex], _ type: MTLPrimitiveType, _ pipeline: MTLRenderPipelineState, size: Float = 0) {
            guard !vertices.isEmpty, let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<LineVertex>.stride, options: .storageModeShared) else { return }
            uniforms.size = size * scale
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: type, vertexStart: 0, vertexCount: vertices.count)
        }
        draw(fill, .triangle, overlayLines)
        draw(wire, .line, overlayLines)
        if edit.part == .vertices {
            draw(at.indices.filter { !edit.vertices.contains(UInt32($0)) }.map { LineVertex(position: at[$0], color: faint) }, .point, overlayPoints, size: 5)
        }
        // The chosen corners, or the ends of the chosen edges, as dots.
        if edit.part != .faces {
            draw(corners.sorted().map { LineVertex(position: at[Int($0)], color: ice) }, .point, overlayPoints, size: edit.part == .vertices ? 8 : 6)
        }
    }

    // MARK: Lines

    private func grid() -> [LineVertex] {
        var out: [LineVertex] = []
        let faint = SIMD4<Float>(1, 1, 1, 0.07)
        for i in -10...10 where i != 0 {
            let t = Float(i)
            out += [LineVertex(position: SIMD3(t, 0, -10), color: faint), LineVertex(position: SIMD3(t, 0, 10), color: faint)]
            out += [LineVertex(position: SIMD3(-10, 0, t), color: faint), LineVertex(position: SIMD3(10, 0, t), color: faint)]
        }
        let x = SIMD4<Float>(0.86, 0.38, 0.38, 0.55)
        let z = SIMD4<Float>(0.38, 0.52, 0.92, 0.55)
        out += [LineVertex(position: SIMD3(-10, 0, 0), color: x), LineVertex(position: SIMD3(10, 0, 0), color: x)]
        out += [LineVertex(position: SIMD3(0, 0, -10), color: z), LineVertex(position: SIMD3(0, 0, 10), color: z)]
        return out
    }

    /// The lines that stand for something with no surface here.
    private func standIn(for node: SceneNode, bounds: [Float]?, world: simd_float4x4, picked: Bool, into out: inout [LineVertex]) {
        let color = picked ? SIMD4<Float>(Self.ice, 1) : SIMD4<Float>(0.72, 0.74, 0.78, 0.85)
        let segments: [(SIMD3<Float>, SIMD3<Float>)]
        switch node.kind {
        case "light":
            let d: Float = 0.3, e: Float = 0.21
            segments = [(SIMD3(-d, 0, 0), SIMD3(d, 0, 0)), (SIMD3(0, -d, 0), SIMD3(0, d, 0)), (SIMD3(0, 0, -d), SIMD3(0, 0, d)),
                        (SIMD3(-e, -e, 0), SIMD3(e, e, 0)), (SIMD3(-e, e, 0), SIMD3(e, -e, 0)), (SIMD3(0, -e, -e), SIMD3(0, e, e)), (SIMD3(0, -e, e), SIMD3(0, e, -e))]
        case "camera":
            let far: [SIMD3<Float>] = [SIMD3(-0.4, -0.3, -1), SIMD3(0.4, -0.3, -1), SIMD3(0.4, 0.3, -1), SIMD3(-0.4, 0.3, -1)]
            segments = far.map { (SIMD3(0, 0, 0), $0) } + (0..<4).map { (far[$0], far[($0 + 1) % 4]) } + [(SIMD3(-0.15, 0.35, -1), SIMD3(0, 0.5, -1)), (SIMD3(0, 0.5, -1), SIMD3(0.15, 0.35, -1))]
        case "mesh":
            let b = bounds.flatMap { $0.count == 6 && $0[3] >= $0[0] ? $0 : nil } ?? [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5]
            let c = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? b[0] : b[3], i & 2 == 0 ? b[1] : b[4], i & 4 == 0 ? b[2] : b[5]) }
            segments = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)].map { (c[$0.0], c[$0.1]) }
        default:
            segments = [(SIMD3(-0.5, 0, 0), SIMD3(0.5, 0, 0)), (SIMD3(0, -0.5, 0), SIMD3(0, 0.5, 0)), (SIMD3(0, 0, -0.5), SIMD3(0, 0, 0.5))]
        }
        for (a, b) in segments {
            let p = world * SIMD4(a, 1), q = world * SIMD4(b, 1)
            out += [LineVertex(position: SIMD3(p.x, p.y, p.z), color: color), LineVertex(position: SIMD3(q.x, q.y, q.z), color: color)]
        }
    }
}
