import MetalKit
import ModelCore
import simd

/// Draws a scene: each mesh with its material run per pixel, everything
/// without a surface as a stand-in drawn in lines (a cross for an empty, a
/// burst for a light, a frustum for a camera, a box for a mesh that isn't
/// here), and the floor grid. Proton's `gl.js` and `viewport.js`, on Metal.
/// Drawn only when something changes, so a still scene costs nothing.
@MainActor
final class ModelRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lines: MTLRenderPipelineState
    private let solid: MTLDepthStencilState
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
        } catch {
            return nil
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let solid = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.solid = solid
        super.init()
    }

    /// The pipeline for a material's program, compiled the first time.
    private func surface(_ shader: SceneShader?) -> MTLRenderPipelineState? {
        let key = SceneShaderSource.key(shader)
        if let made = surfaces[key] { return made }
        do {
            let library = try device.makeLibrary(source: SceneShaderSource.surface(shader), options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "surfaceVertex")
            d.fragmentFunction = library.makeFunction(name: "surfaceFragment")
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
            let made = try device.makeRenderPipelineState(descriptor: d)
            surfaces[key] = made
            return made
        } catch {
            // A material that won't compile draws in the plain grey.
            return key == "plain" ? nil : surface(nil)
        }
    }

    /// An object's buffers, made again only when its mesh or stack changes.
    private func held(_ node: SceneNode, _ mesh: SceneMeshData) -> Held? {
        if let kept = buffers[node.id], kept.shape == node.shape { return kept }
        guard !mesh.triangles.isEmpty,
              let positions = device.makeBuffer(bytes: mesh.positions, length: mesh.positions.count * 4, options: .storageModeShared),
              let indices = device.makeBuffer(bytes: mesh.triangles, length: mesh.triangles.count * 4, options: .storageModeShared) else { return nil }
        // No normals: zeros, and the fragment stage works out the face's own.
        let normals = mesh.normals.count == mesh.positions.count
            ? device.makeBuffer(bytes: mesh.normals, length: mesh.normals.count * 4, options: .storageModeShared)
            : device.makeBuffer(length: mesh.positions.count * 4, options: .storageModeShared)
        guard let normals else { return nil }
        let made = Held(shape: node.shape, positions: positions, normals: normals, indices: indices, count: mesh.triangles.count, closed: mesh.closed)
        buffers[node.id] = made
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
        for node in nodes {
            let world = worlds[node.id] ?? matrix_identity_float4x4
            let picked = node.id == model.selected
            let mesh = node.kind == "mesh" && !node.mesh.isEmpty ? model.document?.mesh(for: node) : nil
            guard let mesh, let held = held(node, mesh), let pipeline = surface(node.material.isEmpty ? nil : shaders[node.material]) else {
                standIn(for: node, bounds: mesh?.bounds, world: world, picked: picked, into: &stand)
                continue
            }
            let modelView = viewMatrix * world
            let upper = simd_float3x3(SIMD3(modelView.columns.0.x, modelView.columns.0.y, modelView.columns.0.z),
                                      SIMD3(modelView.columns.1.x, modelView.columns.1.y, modelView.columns.1.z),
                                      SIMD3(modelView.columns.2.x, modelView.columns.2.y, modelView.columns.2.z))
            var object = ObjectUniforms(modelView: modelView, normal: upper.inverse.transpose, picked: picked ? 1 : 0)
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

    /// How far the scene reaches from the camera's target, for the far plane.
    private func boxSpan(_ model: ModelWorkspaceModel) -> Float {
        model.boxes().flatMap(\.corners).map { simd_length($0 - model.camera.target) }.max() ?? 10
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
