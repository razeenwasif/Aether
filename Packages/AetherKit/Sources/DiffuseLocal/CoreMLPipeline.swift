import CoreGraphics
import CoreML
import DiffuseCore
import Dispatch
import Foundation
import OSLog
import StableDiffusion

/// Image generation on this Mac with Apple's Core ML Stable Diffusion
/// pipeline: an SDXL model loaded once and kept for the runs after, on the
/// GPU (Apple's choice for SDXL on a Mac), and let go only when the system
/// says memory is critically short: its warnings come often on a 16 GB Mac
/// with other apps open, and loading again costs most of a minute. One run
/// at a time, as `LocalBackend` sends them.
public final class CoreMLPipeline: LocalPipeline, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.razeen.aether", category: "local")
    private let lock = NSLock()
    private var loaded: (folder: URL, pipeline: StableDiffusionXLPipeline)?
    private var pressure: DispatchSourceMemoryPressure?

    public init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Self.log.notice("memory is critically short: letting the model go")
            self?.unload()
        }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    /// Load `model`, if it isn't the one loaded. The first load of a model
    /// on a Mac is slow: Core ML specialises it for this GPU, once.
    public func prepare(_ model: LocalModel) throws {
        _ = try pipeline(for: model)
    }

    public func generate(_ plan: LocalPlan, model: LocalModel, startingImage: CGImage?,
                         progress: @escaping @Sendable (Int, Int) -> Bool) throws -> [CGImage] {
        let pipeline = try pipeline(for: model)
        var config = StableDiffusionXLPipeline.Configuration(prompt: plan.prompt)
        config.negativePrompt = plan.negative
        config.imageCount = plan.count
        config.stepCount = plan.steps
        config.seed = plan.seed
        config.guidanceScale = Float(plan.cfg)
        switch plan.scheduler {
        case .dpmSolverMultistep(let karras):
            config.schedulerType = .dpmSolverMultistepScheduler
            config.schedulerTimestepSpacing = karras ? .karras : .linspace
        case .pndm:
            config.schedulerType = .pndmScheduler
        }
        // SDXL's VAE, as Apple's own sample sets it up.
        config.encoderScaleFactor = 0.13025
        config.decoderScaleFactor = 0.13025
        config.originalSize = Float(model.side)
        config.targetSize = Float(model.side)
        config.useDenoisedIntermediates = true
        // SDXL has no safety checker in this pipeline; say so rather than ask.
        config.disableSafety = true
        if let startingImage {
            config.startingImage = Self.fill(startingImage, side: model.side)
            config.strength = Float(plan.strength)
        }
        let clock = StageClock()
        let images = try pipeline.generateImages(configuration: config) { step in
            clock.step()
            return progress(step.step + 1, step.stepCount)
        }
        let (before, stepping, after) = clock.stages()
        Self.log.notice("made \(images.count) picture(s), \(plan.steps) steps: prompt \(before, format: .fixed(precision: 1)) s, steps \(stepping, format: .fixed(precision: 1)) s, decode \(after, format: .fixed(precision: 1)) s")
        return images.compactMap { $0 }
    }

    /// Let go of the loaded model, as when memory is short.
    public func unload() {
        lock.withLock {
            loaded?.pipeline.unloadResources()
            loaded = nil
        }
    }

    private func pipeline(for model: LocalModel) throws -> StableDiffusionXLPipeline {
        try lock.withLock {
            if let loaded, loaded.folder == model.folder { return loaded.pipeline }
            loaded?.pipeline.unloadResources()
            loaded = nil
            let started = Date.now
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            let pipeline = try StableDiffusionXLPipeline(resourcesAt: model.folder, configuration: configuration, reduceMemory: false)
            try pipeline.loadResources()
            loaded = (model.folder, pipeline)
            Self.log.notice("loaded \(model.name, privacy: .public) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1)) s")
            return pipeline
        }
    }

    /// A picture made the model's square: scaled to cover it and cropped to
    /// its middle, as the model makes only that size.
    static func fill(_ picture: CGImage, side: Int) -> CGImage? {
        guard picture.width != side || picture.height != side else { return picture }
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let scale = max(Double(side) / Double(picture.width), Double(side) / Double(picture.height))
        let w = Double(picture.width) * scale, h = Double(picture.height) * scale
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return context.makeImage()
    }
}

/// When a run's stages end: the prompt encoded (the first step's start),
/// the last step, and the pictures decoded.
private final class StageClock: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date.now
    private var first: Date?
    private var last: Date?
    private var firstStep: TimeInterval = 0

    func step() {
        lock.withLock {
            let now = Date.now
            if first == nil { first = now }
            last = now
        }
    }

    /// Seconds before the first step ended, stepping after it, and after the last.
    func stages() -> (Double, Double, Double) {
        lock.withLock {
            let end = Date.now
            guard let first, let last else { return (end.timeIntervalSince(started), 0, 0) }
            return (first.timeIntervalSince(started), last.timeIntervalSince(first), end.timeIntervalSince(last))
        }
    }
}
