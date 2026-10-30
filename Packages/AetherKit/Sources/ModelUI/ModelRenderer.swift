import MetalKit
import MetalPerformanceShaders
import ModelCore
import os
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
    /// Bound where nothing casts a shadow: the view, and a render's lights
    /// that can't.
    private let noShadows: MTLTexture
    private var shadowPipeline: MTLRenderPipelineState?
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

    /// A scene light, as the shader reads it (`SceneLight`).
    private struct LightUniform {
        var at: SIMD4<Float>
        var color: SIMD4<Float>
        var shadow: simd_float4x4
    }

    private struct LightsHead {
        var count: Int32
        var bias: Float
        var offset: Float = 0
        var pad: Float = 0
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
        let empty = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        empty.textureType = .type2DArray
        empty.arrayLength = 1
        empty.usage = .shaderRead
        empty.storageMode = .private
        guard let noShadows = device.makeTexture(descriptor: empty) else { return nil }
        self.noShadows = noShadows
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
        // The scene's lights shade the view too, without shadows; none, the
        // key light.
        var lights = Self.sceneLights(nodes, worlds: worlds, view: viewMatrix).map { light in
            var one = light
            one.color.w = -1
            return one
        }
        var head = LightsHead(count: Int32(lights.count), bias: 0)
        if lights.isEmpty { lights = [LightUniform(at: .zero, color: SIMD4(0, 0, 0, -1), shadow: matrix_identity_float4x4)] }
        encoder.setFragmentBytes(&head, length: MemoryLayout<LightsHead>.stride, index: 5)
        encoder.setFragmentBytes(&lights, length: lights.count * MemoryLayout<LightUniform>.stride, index: 6)
        encoder.setFragmentTexture(noShadows, index: 0)

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

    /// How a render is made, beyond its size.
    struct RenderSettings {
        var width: Int
        var height: Int
        var transparent = false
        /// A camera object to look through, or the view's camera.
        var camera: String?
        /// A floor under everything, for shadows to fall on.
        var floor = true
        var shadows = true
        /// A path-traced render smoothed by the denoiser.
        var denoise = true
    }

    /// The scene `width` by `height`, through the view's camera or one of the
    /// scene's: drawn at twice that with 4× multisampling and scaled down,
    /// without the grid, the stand-ins, Edit mode's cage or the chosen
    /// object's tint. Lit by the scene's lights (the key light when it has
    /// none), each casting a shadow from a map of its own, onto a floor
    /// under everything if asked for. Then again for depth, near white and
    /// far black across what the scene spans in front of the camera.
    func render(_ settings: RenderSettings) async throws -> Pictures {
        let state = Self.signposter.beginInterval("render", "\(settings.width) × \(settings.height)")
        defer { Self.signposter.endInterval("render", state) }
        guard let model, let document = model.document else { throw RenderFailure(reason: "open a scene to render") }
        let (width, height) = (settings.width, settings.height)
        let scale = max(1, min(2, 8192 / max(width, height)))
        let (w, h) = (width * scale, height * scale)
        let nodes = document.state.objects
        let worlds = SceneMath.worlds(nodes)
        let lens = settings.camera.flatMap { id in nodes.first { $0.id == id && $0.kind == "camera" } }
        let view = lens.map { SceneMath.view(through: worlds[$0.id] ?? matrix_identity_float4x4) } ?? model.camera.view
        let fov = lens.map { Float($0.fov) * .pi / 180 } ?? SceneMath.fov

        // What casts: every mesh drawn, with its box in the world.
        let meshes = nodes.filter { $0.kind == "mesh" && !$0.mesh.isEmpty }.compactMap { node -> (SceneNode, SceneMeshData, simd_float4x4)? in
            let mesh = document.mesh(for: node)
            return mesh.triangles.isEmpty ? nil : (node, mesh, worlds[node.id] ?? matrix_identity_float4x4)
        }
        let corners = meshes.flatMap { SceneMath.corners(bounds: $0.1.bounds, world: $0.2) }
        var lo = corners.first ?? .zero, hi = corners.first ?? .zero
        for c in corners {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        let centre = (lo + hi) / 2
        let radius = max(0.25, simd_length(hi - lo) / 2)
        let floor = settings.floor && !corners.isEmpty ? floorMesh(at: lo.y, around: centre, reach: radius * 8) : nil
        let seen = corners + (floor.map { _ in [-1, 1].flatMap { x in [-1, 1].map { z in SIMD3(centre.x + x * radius * 8, lo.y, centre.z + z * radius * 8) } } } ?? [])

        // What's in front of the camera, for the depth pass and the planes.
        let depths = seen.map { -(view * SIMD4($0, 1)).z }.filter { $0 > 0 }
        let nearest = max(0.01, (depths.min() ?? 0.1) * 0.98)
        let farthest = max(nearest * 1.01, (depths.max() ?? 10) * 1.02)
        let proj = SceneMath.perspective(aspect: Float(width) / Float(max(height, 1)), near: max(0.005, nearest * 0.5), far: farthest * 1.5, fov: fov)
        let key = view * SIMD4(Self.key, 0)
        var frame = FrameUniforms(proj: proj, light: SIMD3(key.x, key.y, key.z), tint: Self.ice)
        let shaders = Dictionary(document.state.shaders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // The lights: the scene's, or the key light as a sun. Each that can,
        // up to four, casts a shadow from a map: a sun's square on to what
        // casts, a point's looking at it from outside it.
        var lights = Self.sceneLights(nodes, worlds: worlds, view: view)
        var world: [simd_float4x4] = Self.sceneLightWorlds(nodes, worlds: worlds)
        if lights.isEmpty {
            let toward = Self.key
            lights = [LightUniform(at: SIMD4(key.x, key.y, key.z, 0), color: SIMD4(3.2, 3.2, 3.2, -1), shadow: matrix_identity_float4x4)]
            world = [Self.sunWorld(toward: toward)]
        }
        var casts: [(layer: Int, clip: simd_float4x4)] = []
        if settings.shadows, !meshes.isEmpty {
            for i in lights.indices where casts.count < 4 {
                guard let clip = Self.shadowClip(lights[i], world: world[i], centre: centre, radius: radius) else { continue }
                lights[i].color.w = Float(casts.count)
                lights[i].shadow = clip * view.inverse
                casts.append((casts.count, clip))
            }
        }
        // Two and a half texels of a sun's map, along the surface's normal.
        var head = LightsHead(count: Int32(lights.count), bias: 0.0003, offset: 2.5 * 2 * radius * 1.05 / Float(Self.shadowSize))

        if depthPipeline == nil { try makeRenderPipelines() }
        func texture(_ format: MTLPixelFormat, width: Int, height: Int, samples: Int = 1, layers: Int = 0, usage: MTLTextureUsage, storage: MTLStorageMode) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            if layers > 0 {
                d.textureType = .type2DArray
                d.arrayLength = layers
            }
            d.usage = usage
            d.storageMode = storage
            guard let made = device.makeTexture(descriptor: d) else { throw RenderFailure(reason: "the GPU couldn’t make a \(width) × \(height) picture") }
            return made
        }
        let color = try texture(.bgra8Unorm, width: w, height: h, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        let depthTarget = try texture(.depth32Float, width: w, height: h, samples: Self.sampleCount, usage: .renderTarget, storage: .private)
        // Resolved at the size drawn, then scaled on the GPU to the size
        // asked for, into textures the CPU reads (§7b: Core Graphics took
        // 20–30 ms a picture to scale them on the main thread).
        let readable: MTLStorageMode = device.hasUnifiedMemory ? .shared : .managed
        let scaled = scale > 1
        let beauty = try texture(.bgra8Unorm, width: w, height: h, usage: scaled ? [.renderTarget, .shaderRead] : .renderTarget, storage: scaled ? .private : readable)
        let deep = try texture(.bgra8Unorm, width: w, height: h, usage: scaled ? [.renderTarget, .shaderRead] : .renderTarget, storage: scaled ? .private : readable)
        let beautyOut = scaled ? try texture(.bgra8Unorm, width: width, height: height, usage: [.shaderWrite, .shaderRead], storage: readable) : beauty
        let deepOut = scaled ? try texture(.bgra8Unorm, width: width, height: height, usage: [.shaderWrite, .shaderRead], storage: readable) : deep
        let maps = casts.isEmpty ? noShadows : try texture(.depth32Float, width: Self.shadowSize, height: Self.shadowSize, layers: casts.count, usage: [.renderTarget, .shaderRead], storage: .private)

        guard let commands = queue.makeCommandBuffer() else { throw RenderFailure(reason: "the GPU is busy") }
        // The shadow maps: each light's view of what casts, depth only, both
        // sides of every face, so where a thing meets the floor its shadow
        // meets it too.
        for cast in casts {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = maps
            pass.depthAttachment.slice = cast.layer
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass), let shadowPipeline else { throw RenderFailure(reason: "the GPU is busy") }
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(solid)
            encoder.setFrontFacing(.counterClockwise)
            for (node, mesh, placed) in meshes {
                guard let held = held(node.id, node.shape, mesh) else { continue }
                var clip = cast.clip * placed
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(held.positions, offset: 0, index: 0)
                encoder.setVertexBuffer(held.normals, offset: 0, index: 3)
                encoder.setVertexBytes(&clip, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: held.count, indexType: .uint32, indexBuffer: held.indices, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }
        if lights.isEmpty { lights = [LightUniform(at: .zero, color: SIMD4(0, 0, 0, -1), shadow: matrix_identity_float4x4)] }
        for (resolve, isDepth) in [(beauty, false), (deep, true)] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.colorAttachments[0].clearColor = isDepth ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                : settings.transparent ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) : MTLClearColor(red: 0.028, green: 0.031, blue: 0.04, alpha: 1)
            pass.depthAttachment.texture = depthTarget
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw RenderFailure(reason: "the GPU is busy") }
            encoder.setDepthStencilState(solid)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setFragmentBytes(&head, length: MemoryLayout<LightsHead>.stride, index: 5)
            encoder.setFragmentBytes(&lights, length: lights.count * MemoryLayout<LightUniform>.stride, index: 6)
            encoder.setFragmentTexture(maps, index: 0)
            var range = SIMD2<Float>(nearest, farthest)
            let drawn: [(String, String, SceneMeshData, simd_float4x4, SceneShader?)] = meshes.map { ($0.0.id, $0.0.shape, $0.1, $0.2, $0.0.material.isEmpty ? nil : shaders[$0.0.material]) }
                + (floor.map { [("floor", "floor:\(lo.y):\(centre):\(radius)", $0, matrix_identity_float4x4, nil)] } ?? [])
            for (id, shape, mesh, placed, shader) in drawn {
                guard let held = held(id, shape, mesh), let pipeline = isDepth ? depthPipeline : surface(shader) else { continue }
                let modelView = view * placed
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
        if scaled {
            let lanczos = MPSImageLanczosScale(device: device)
            lanczos.encode(commandBuffer: commands, sourceTexture: beauty, destinationTexture: beautyOut)
            lanczos.encode(commandBuffer: commands, sourceTexture: deep, destinationTexture: deepOut)
        }
        if readable == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: beautyOut)
            blit.synchronize(resource: deepOut)
            blit.endEncoding()
        }
        // Waited for without holding the main thread.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            commands.addCompletedHandler { buffer in
                if let error = buffer.error { done.resume(throwing: RenderFailure(reason: error.localizedDescription)) } else { done.resume() }
            }
            commands.commit()
        }
        buffers["floor"] = nil
        return Pictures(beauty: try Self.image(beautyOut, opaque: !settings.transparent),
                        depth: try Self.image(deepOut, opaque: true))
    }

    /// The depth pass's and the shadow maps' pipelines, made the first time
    /// a render needs them.
    private func makeRenderPipelines() throws {
        let library = try device.makeLibrary(source: SceneShaderSource.surface(nil), options: nil)
        depthPipeline = try device.makeRenderPipelineState(descriptor: Self.surfaceDescriptor(library, fragment: "depthFragment"))
        let d = Self.surfaceDescriptor(library, fragment: "depthFragment")
        d.vertexFunction = library.makeFunction(name: "shadowVertex")
        d.fragmentFunction = nil
        d.colorAttachments[0].pixelFormat = .invalid
        d.rasterSampleCount = 1
        shadowPipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Path traced

    private var tracer: PathTracer?

    /// Whether this Mac's GPU can trace rays.
    var canTrace: Bool { device.supportsRaytracing }

    /// The render path traced: the scene's triangles, its materials and its
    /// lights (each with a size, so shadows soften), light bouncing off
    /// everything and in from a dim room round it, `samples` a pixel, then
    /// denoised if the settings ask. The depth pass is the quick render's. `progress` hears the samples so
    /// far after each pass and answers whether to go on.
    func pathTrace(_ settings: RenderSettings, samples: Int, progress: @MainActor (Int) -> Bool) async throws -> Pictures {
        guard let model, let document = model.document else { throw RenderFailure(reason: "open a scene to render") }
        if tracer == nil { tracer = PathTracer(device: device) }
        guard let tracer else { throw RenderFailure(reason: "this Mac’s GPU can’t trace rays: use the quick render") }
        // The depth pass, and a check the scene can be drawn, from the quick
        // render at the same settings.
        let quick = try await render(settings)
        let nodes = document.state.objects
        let worlds = SceneMath.worlds(nodes)
        let lens = settings.camera.flatMap { id in nodes.first { $0.id == id && $0.kind == "camera" } }
        let view = lens.map { SceneMath.view(through: worlds[$0.id] ?? matrix_identity_float4x4) } ?? model.camera.view
        let fov = lens.map { Float($0.fov) * .pi / 180 } ?? SceneMath.fov

        var scene = PathTracer.Scene()
        let materials = document.state.materials.map(\.id)
        let shaders = Dictionary(document.state.shaders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        scene.shaders = materials.map { shaders[$0] }
        var corners: [SIMD3<Float>] = []
        for node in nodes where node.kind == "mesh" && !node.mesh.isEmpty {
            let mesh = document.mesh(for: node)
            guard !mesh.triangles.isEmpty else { continue }
            let world = worlds[node.id] ?? matrix_identity_float4x4
            let slot = materials.firstIndex(of: node.material).map { UInt32($0 + 1) } ?? 0
            scene.add(mesh, world: world, slot: slot)
            corners += SceneMath.corners(bounds: mesh.bounds, world: world)
        }
        guard !corners.isEmpty else { throw RenderFailure(reason: "there's no mesh to render") }
        var lo = corners[0], hi = corners[0]
        for c in corners {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        let centre = (lo + hi) / 2
        let radius = max(0.25, simd_length(hi - lo) / 2)
        if settings.floor {
            scene.add(floorMesh(at: lo.y, around: centre, reach: radius * 8), world: matrix_identity_float4x4, slot: 0)
        }
        // Lights in the world, each with a size: a point a ball a tenth of a
        // metre across, a sun three degrees wide.
        for node in nodes where node.kind == "light" {
            guard let light = node.light, let world = worlds[node.id] else { continue }
            let c = light.color.count == 3 ? light.color : [1, 1, 1]
            let rgb = SIMD3(Float(c[0]), Float(c[1]), Float(c[2])) * Float(light.strength)
            if light.kind == "sun" {
                scene.lights.append(.init(at: SIMD4(simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)), 0), color: SIMD4(rgb, tan(1.5 * .pi / 180))))
            } else {
                scene.lights.append(.init(at: SIMD4(world.columns.3.x, world.columns.3.y, world.columns.3.z, 1), color: SIMD4(rgb, 0.05)))
            }
        }
        if scene.lights.isEmpty {
            scene.lights = [.init(at: SIMD4(Self.key, 0), color: SIMD4(3.2, 3.2, 3.2, tan(1.5 * .pi / 180)))]
        }
        scene.lights = Array(scene.lights.prefix(16))
        let picture = try await tracer.trace(scene, eye: view.inverse, fov: fov, width: settings.width, height: settings.height,
                                             samples: samples, transparent: settings.transparent, denoise: settings.denoise, progress: progress)
        return Pictures(beauty: try Self.image(picture, opaque: !settings.transparent), depth: quick.depth)
    }

    /// A shadow map's side, in texels.
    static let shadowSize = 2048

    /// A square floor at height `y`, `reach` out from `centre` each way.
    private func floorMesh(at y: Float, around centre: SIMD3<Float>, reach: Float) -> SceneMeshData {
        let (x0, x1, z0, z1) = (centre.x - reach, centre.x + reach, centre.z - reach, centre.z + reach)
        return SceneMeshData(positions: [x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1], normals: [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0],
                             triangles: [0, 2, 1, 0, 3, 2], bounds: [x0, y, z0, x1, y, z1], closed: false, problem: nil)
    }

    /// The scene's lights as the shader reads them, in the eye space of
    /// `view`, unshadowed: a point where it is, a sun the way towards it (its
    /// own +Z, as it shines down −Z).
    private static func sceneLights(_ nodes: [SceneNode], worlds: [String: simd_float4x4], view: simd_float4x4) -> [LightUniform] {
        nodes.compactMap { node -> LightUniform? in
            guard node.kind == "light", let light = node.light, let world = worlds[node.id] else { return nil }
            let c = light.color.count == 3 ? light.color : [1, 1, 1]
            let color = SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), 0) * Float(light.strength)
            if light.kind == "sun" {
                let toward = view * SIMD4(simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)), 0)
                return LightUniform(at: SIMD4(simd_normalize(SIMD3(toward.x, toward.y, toward.z)), 0), color: SIMD4(color.x, color.y, color.z, -1), shadow: matrix_identity_float4x4)
            }
            let at = view * world.columns.3
            return LightUniform(at: SIMD4(at.x, at.y, at.z, 1), color: SIMD4(color.x, color.y, color.z, -1), shadow: matrix_identity_float4x4)
        }.prefix(8).map { $0 }
    }

    /// The scene lights' places in the world, in the same order.
    private static func sceneLightWorlds(_ nodes: [SceneNode], worlds: [String: simd_float4x4]) -> [simd_float4x4] {
        nodes.filter { $0.kind == "light" && $0.light != nil && worlds[$0.id] != nil }.prefix(8).map { worlds[$0.id]! }
    }

    /// A sun's place for the key light: its +Z towards `toward`.
    private static func sunWorld(toward: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(toward)
        let up: SIMD3<Float> = abs(z.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(0, 0, 0, 1)))
    }

    /// The view from `eye` towards `target`, with an up that isn't along it.
    private static func look(from eye: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let up: SIMD3<Float> = abs(z.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    /// From the world into a light's shadow map, or `nil` for a point light
    /// inside what casts (it would need a map every way).
    private static func shadowClip(_ light: LightUniform, world: simd_float4x4, centre: SIMD3<Float>, radius: Float) -> simd_float4x4? {
        if light.at.w < 0.5 {
            let toward = simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
            let view = look(from: centre + toward * radius * 3, at: centre)
            let r = radius * 1.05
            return SceneMath.orthographic(left: -r, right: r, bottom: -r, top: r, near: radius * 0.5, far: radius * 12) * view
        }
        let at = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let distance = simd_length(centre - at)
        guard distance > radius * 1.05 else { return nil }
        let fov = min(150 * Float.pi / 180, max(10 * Float.pi / 180, 2 * asin(min(radius / distance, 0.999)) * 1.15))
        let near = max(0.02, distance - radius * 1.2)
        return SceneMath.perspective(aspect: 1, near: near, far: distance + radius * 10, fov: fov) * look(from: at, at: centre)
    }

    /// A render's steps, timed for Instruments under `dev.razeen.aether` /
    /// `render` (§7a).
    static let signposter = OSSignposter(subsystem: "dev.razeen.aether", category: "render")

    /// A rendered texture, at the size it is, as a picture: its bytes
    /// copied once, straight into the picture's.
    private static func image(_ texture: MTLTexture, opaque: Bool) throws -> CGImage {
        let state = signposter.beginInterval("readback", "\(texture.width) × \(texture.height)")
        defer { signposter.endInterval("readback", state) }
        let (w, h) = (texture.width, texture.height)
        var bytes = Data(count: w * h * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst).rawValue
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RenderFailure(reason: "couldn’t make the picture")
        }
        return image
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
