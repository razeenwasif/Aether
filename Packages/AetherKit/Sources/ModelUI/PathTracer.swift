import Metal
import ModelCore
import simd

/// Render's path tracer: the scene's triangles in the world, in one of
/// Metal's acceleration structures, traced a few samples a pixel a pass, so
/// a render shows its progress and can be stopped.
@MainActor
final class PathTracer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: (trace: MTLComputePipelineState, finish: MTLComputePipelineState)] = [:]

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// What's traced: triangles in the world, each with its material's slot.
    struct Scene {
        var places: [SIMD3<Float>] = []
        var normals: [SIMD4<Float>] = []
        var objects: [SIMD4<Float>] = []
        var indices: [UInt32] = []
        var slots: [UInt32] = []
        var shaders: [SceneShader?] = []
        var lights: [Light] = []

        struct Light {
            var at: SIMD4<Float>
            var color: SIMD4<Float>
        }

        /// A mesh placed by `world`, drawn with the material in `slot`.
        mutating func add(_ mesh: SceneMeshData, world: simd_float4x4, slot: UInt32) {
            let base = UInt32(places.count)
            let normal = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                       SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                       SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)).inverse.transpose
            let count = mesh.positions.count / 3
            let hasNormals = mesh.normals.count == mesh.positions.count
            for v in 0..<count {
                let p = SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])
                let w = world * SIMD4(p, 1)
                places.append(SIMD3(w.x, w.y, w.z))
                objects.append(SIMD4(p, 1))
                if hasNormals {
                    let n = normal * SIMD3(mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2])
                    normals.append(SIMD4(simd_length(n) > 1e-8 ? simd_normalize(n) : .zero, 0))
                } else {
                    normals.append(.zero)
                }
            }
            indices += mesh.triangles.map { $0 + base }
            slots += Array(repeating: slot, count: mesh.triangles.count / 3)
        }
    }

    struct Frame {
        var eye: simd_float4x4
        var tanHalf: Float
        var aspect: Float
        var width: UInt32
        var height: UInt32
        var sample: UInt32
        var samples: UInt32
        var lights: UInt32
        var bounces: UInt32
        var background: SIMD4<Float>
    }

    init?(device: MTLDevice) {
        guard device.supportsRaytracing, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }

    /// `scene` through `eye` (the camera's place in the world), `width` by
    /// `height`, `samples` a pixel, `progress` told after each pass with the
    /// samples so far; it answers whether to go on.
    func trace(_ scene: Scene, eye: simd_float4x4, fov: Float, width: Int, height: Int, samples: Int, transparent: Bool,
               progress: @MainActor (Int) -> Bool) async throws -> MTLTexture {
        guard !scene.indices.isEmpty else { throw Failure(reason: "there's nothing to trace") }
        let key = SceneShaderSource.tracerKey(scene.shaders)
        if pipelines[key] == nil {
            do {
                let library = try await device.makeLibrary(source: SceneShaderSource.tracer(scene.shaders), options: nil)
                guard let trace = library.makeFunction(name: "trace"), let finish = library.makeFunction(name: "finish") else { throw Failure(reason: "the tracer didn’t compile") }
                pipelines[key] = (try await device.makeComputePipelineState(function: trace), try await device.makeComputePipelineState(function: finish))
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(reason: "the tracer didn’t compile: \(error.localizedDescription)")
            }
        }
        guard let pipeline = pipelines[key] else { throw Failure(reason: "the tracer didn’t compile") }

        // The triangles, and the structure rays are found against.
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let made = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }) else {
                throw Failure(reason: "the GPU is out of room")
            }
            return made
        }
        let packed = scene.places.flatMap { [$0.x, $0.y, $0.z] }
        let vertexBuffer = try buffer(packed)
        let indexBuffer = try buffer(scene.indices)
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = vertexBuffer
        geometry.vertexStride = 12
        geometry.vertexFormat = .float3
        geometry.indexBuffer = indexBuffer
        geometry.indexType = .uint32
        geometry.triangleCount = scene.indices.count / 3
        let described = MTLPrimitiveAccelerationStructureDescriptor()
        described.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: described)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let building = queue.makeCommandBuffer(), let builder = building.makeAccelerationStructureCommandEncoder() else {
            throw Failure(reason: "the GPU couldn’t hold the scene")
        }
        builder.build(accelerationStructure: accel, descriptor: described, scratchBuffer: scratch, scratchBufferOffset: 0)
        builder.endEncoding()
        building.commit()

        let places = try buffer(scene.places.map { SIMD4($0, 1) })
        let normals = try buffer(scene.normals)
        let objects = try buffer(scene.objects)
        let slots = try buffer(scene.slots)
        let (constants, starts) = SceneShaderSource.tracerConstants(scene.shaders)
        let k = try buffer(constants)
        let start = try buffer(starts)
        let lights = try buffer(scene.lights.isEmpty ? [Scene.Light(at: .zero, color: .zero)] : scene.lights)

        let sumDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        sumDescriptor.usage = [.shaderRead, .shaderWrite]
        sumDescriptor.storageMode = .private
        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outDescriptor.usage = [.shaderWrite, .shaderRead]
        outDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let sum = device.makeTexture(descriptor: sumDescriptor), let out = device.makeTexture(descriptor: outDescriptor) else {
            throw Failure(reason: "the GPU couldn’t make a \(width) × \(height) picture")
        }
        // The ground behind, as light the tone curve turns back into it.
        let ground = SIMD3<Float>(0.028, 0.031, 0.04)
        let behind = ground * ground / (SIMD3(repeating: 1) - ground * ground)
        var frame = Frame(eye: eye, tanHalf: tan(fov / 2), aspect: Float(width) / Float(max(height, 1)), width: UInt32(width), height: UInt32(height),
                          sample: 0, samples: 0, lights: UInt32(scene.lights.count), bounces: 5,
                          background: transparent ? SIMD4(0, 0, 0, 0) : SIMD4(behind, 1))
        let groups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
        let group = MTLSize(width: 8, height: 8, depth: 1)

        // Passes of a few samples each, waited for in turn: the first starts
        // the sum.
        let perPass = max(1, min(8, 4_000_000 / max(width * height, 1)))
        var done = 0
        while done < samples {
            frame.sample = UInt32(done)
            frame.samples = UInt32(min(perPass, samples - done))
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Failure(reason: "the GPU is busy") }
            encoder.setComputePipelineState(pipeline.trace)
            encoder.setBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
            encoder.setAccelerationStructure(accel, bufferIndex: 1)
            encoder.setBuffer(normals, offset: 0, index: 2)
            encoder.setBuffer(objects, offset: 0, index: 3)
            encoder.setBuffer(indexBuffer, offset: 0, index: 4)
            encoder.setBuffer(slots, offset: 0, index: 5)
            encoder.setBuffer(k, offset: 0, index: 6)
            encoder.setBuffer(start, offset: 0, index: 7)
            encoder.setBuffer(lights, offset: 0, index: 8)
            encoder.setBuffer(places, offset: 0, index: 9)
            encoder.setTexture(sum, index: 0)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
            encoder.endEncoding()
            try await run(commands)
            done += Int(frame.samples)
            if !progress(done) { break }
        }
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Failure(reason: "the GPU is busy") }
        var count = UInt32(max(done, 1))
        encoder.setComputePipelineState(pipeline.finish)
        encoder.setBytes(&count, length: 4, index: 0)
        encoder.setTexture(sum, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        if out.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: out)
            blit.endEncoding()
        }
        try await run(commands)
        return out
    }

    /// A command buffer run, waited for without holding the main thread.
    private func run(_ commands: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            commands.addCompletedHandler { buffer in
                if let error = buffer.error { done.resume(throwing: Failure(reason: error.localizedDescription)) } else { done.resume() }
            }
            commands.commit()
        }
    }
}
