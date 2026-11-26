import CoreGraphics
import CoreML
import DiffuseCore
import Dispatch
import Foundation
import OSLog
import StableDiffusion

/// Image generation on this Mac with Apple's Core ML Stable Diffusion
/// pipeline: an SDXL model loaded once and kept for the runs after, and let
/// go only when the system says memory is critically short (its warnings
/// come often on a 16 GB Mac with other apps open, and loading again costs
/// most of a minute). One run at a time, as `LocalBackend` sends them.
///
/// The pipeline is built from its parts, as Apple's own loader builds it,
/// so each part runs where it's quickest: the U-Net and the VAE on the GPU
/// (Apple's choice for SDXL on a Mac; the VAE can't use the Neural Engine,
/// which has no float32), the text encoders where `textEncoders` says. And
/// each encoder's output is kept for prompts already seen, so a run that
/// changes only the seed skips encoding.
public final class CoreMLPipeline: LocalPipeline, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.razeen.photon", category: "local")
    private let lock = NSLock()
    private var loaded: (folder: URL, pipeline: StableDiffusionXLPipeline, prompts: PromptCache)?
    private var pressure: DispatchSourceMemoryPressure?
    private var times: RunTimes?

    /// Where the two text encoders run.
    public let textEncoders: MLComputeUnits
    /// Whether encoded prompts are kept for the next run.
    public let cachesPrompts: Bool

    /// The text encoders stay on the GPU by default: measured on an M2 Pro
    /// (RESEARCH_PLAN.md §10a), the GPU encodes a new prompt quickest (about
    /// 2 s, against 4.5–6.4 s on the CPU or the Neural Engine), and kept
    /// prompts take nothing anywhere.
    public init(textEncoders: MLComputeUnits = .cpuAndGPU, cachesPrompts: Bool = true) {
        self.textEncoders = textEncoders
        self.cachesPrompts = cachesPrompts
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Self.log.notice("memory is critically short: letting the model go")
            self?.unload()
        }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    /// How long the last run took, stage by stage.
    public struct RunTimes: Sendable, Equatable {
        /// Loading the model, when this run loaded it.
        public var load: Double?
        /// Encoding the prompts: 0 when all four encodings were kept.
        public var encode: Double
        public var encodings: Int
        public var keptEncodings: Int
        /// The first step, with what comes before it other than encoding.
        public var firstStep: Double
        /// Every step after the first.
        public var steps: Double
        public var decode: Double
        public var total: Double
    }

    public var lastRun: RunTimes? { lock.withLock { times } }

    /// Load `model`, if it isn't the one loaded. The first load of a model
    /// on a Mac is slow: Core ML specialises it for this hardware, once.
    public func prepare(_ model: LocalModel) throws {
        _ = try pipeline(for: model)
    }

    public func generate(_ plan: LocalPlan, model: LocalModel, startingImage: CGImage?,
                         progress: @escaping @Sendable (Int, Int) -> Bool) throws -> [CGImage] {
        let loadStarted = Date.now
        let (pipeline, prompts, loadedNow) = try pipeline(for: model)
        let load = loadedNow ? Date.now.timeIntervalSince(loadStarted) : nil
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
        let before = prompts.counts()
        let images = try pipeline.generateImages(configuration: config) { step in
            clock.step()
            return progress(step.step + 1, step.stepCount)
        }
        let after = prompts.counts()
        let (untilFirst, stepping, decode) = clock.stages()
        let encode = after.seconds - before.seconds
        let run = RunTimes(load: load, encode: encode, encodings: after.encoded - before.encoded, keptEncodings: after.kept - before.kept,
                           firstStep: max(0, untilFirst - encode), steps: stepping, decode: decode, total: untilFirst + stepping + decode)
        lock.withLock { times = run }
        Self.log.notice("""
            made \(images.count) picture(s), \(plan.steps) steps: encoding \(run.encode, format: .fixed(precision: 1)) s \
            (\(run.keptEncodings) of 4 kept), first step \(run.firstStep, format: .fixed(precision: 1)) s, \
            steps \(run.steps, format: .fixed(precision: 1)) s, decode \(run.decode, format: .fixed(precision: 1)) s
            """)
        return images.compactMap { $0 }
    }

    /// Let go of the loaded model, as when memory is short.
    public func unload() {
        lock.withLock {
            loaded?.pipeline.unloadResources()
            loaded = nil
        }
    }

    private func pipeline(for model: LocalModel) throws -> (StableDiffusionXLPipeline, PromptCache, Bool) {
        try lock.withLock {
            if let loaded, loaded.folder == model.folder { return (loaded.pipeline, loaded.prompts, false) }
            loaded?.pipeline.unloadResources()
            loaded = nil
            let started = Date.now
            let prompts = PromptCache(keeps: cachesPrompts)
            let pipeline = try Self.build(model.folder, textEncoders: textEncoders, prompts: prompts)
            try pipeline.loadResources()
            loaded = (model.folder, pipeline, prompts)
            Self.log.notice("loaded \(model.name, privacy: .public) (text encoders on \(Self.name(self.textEncoders), privacy: .public)) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1)) s")
            return (pipeline, prompts, true)
        }
    }

    /// The SDXL pipeline from its parts, as Apple's loader builds it but for
    /// where each part runs.
    static func build(_ folder: URL, textEncoders: MLComputeUnits, prompts: PromptCache) throws -> StableDiffusionXLPipeline {
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        let text = MLModelConfiguration()
        text.computeUnits = textEncoders
        let at = { (name: String) in folder.appending(path: name) }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: at(name).path) }
        let tokenizer = try BPETokenizer(mergesAt: at("merges.txt"), vocabularyAt: at("vocab.json"))
        // The second encoder pads with "!", as Apple's loader sets it up.
        let tokenizer2 = try BPETokenizer(mergesAt: at("merges.txt"), vocabularyAt: at("vocab.json"), padToken: "!")
        let first: TextEncoderXLModel? = exists("TextEncoder.mlmodelc")
            ? KeptTextEncoder(TextEncoderXL(tokenizer: tokenizer, modelAt: at("TextEncoder.mlmodelc"), configuration: text), slot: 1, prompts: prompts)
            : nil
        let second = KeptTextEncoder(TextEncoderXL(tokenizer: tokenizer2, modelAt: at("TextEncoder2.mlmodelc"), configuration: text), slot: 2, prompts: prompts)
        return StableDiffusionXLPipeline(
            textEncoder: first,
            textEncoder2: second,
            unet: Unet(modelAt: at("Unet.mlmodelc"), configuration: gpu),
            unetRefiner: nil,
            decoder: Decoder(modelAt: at("VAEDecoder.mlmodelc"), configuration: gpu),
            encoder: exists("VAEEncoder.mlmodelc") ? Encoder(modelAt: at("VAEEncoder.mlmodelc"), configuration: gpu) : nil,
            reduceMemory: false)
    }

    static func name(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "the CPU"
        case .cpuAndGPU: "the GPU"
        case .cpuAndNeuralEngine: "the Neural Engine"
        case .all: "any unit"
        @unknown default: "\(units.rawValue)"
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

/// Encoded prompts, by encoder and text, kept while the model is loaded:
/// an encoder's output for a text is always the same, so a run whose
/// prompts were seen before needs none of its four encodings. Counts what
/// it encoded, kept and spent, for timing.
final class PromptCache: @unchecked Sendable {
    private let lock = NSLock()
    private let keeps: Bool
    private var kept: [String: TextEncoderXLModel.TextEncoderXLOutput] = [:]
    private var order: [String] = []
    private var encoded = 0
    private var hits = 0
    private var seconds: Double = 0
    /// Prompts kept: a few runs' worth, each a pair of encoders' pair.
    private let room = 32

    init(keeps: Bool) { self.keeps = keeps }

    func output(slot: Int, text: String, encode: () throws -> TextEncoderXLModel.TextEncoderXLOutput) throws -> TextEncoderXLModel.TextEncoderXLOutput {
        let key = "\(slot)\u{0}\(text)"
        if keeps, let hit = lock.withLock({ kept[key] }) {
            lock.withLock { hits += 1 }
            return hit
        }
        let started = Date.now
        let output = try encode()
        let spent = Date.now.timeIntervalSince(started)
        lock.withLock {
            encoded += 1
            seconds += spent
            guard keeps else { return }
            if kept[key] == nil { order.append(key) }
            kept[key] = output
            if order.count > room { kept[order.removeFirst()] = nil }
        }
        return output
    }

    func counts() -> (encoded: Int, kept: Int, seconds: Double) {
        lock.withLock { (encoded, hits, seconds) }
    }
}

/// A text encoder whose outputs `PromptCache` keeps.
struct KeptTextEncoder: TextEncoderXLModel {
    let base: TextEncoderXL
    let slot: Int
    let prompts: PromptCache

    init(_ base: TextEncoderXL, slot: Int, prompts: PromptCache) {
        self.base = base
        self.slot = slot
        self.prompts = prompts
    }

    func loadResources() throws { try base.loadResources() }
    func unloadResources() { base.unloadResources() }

    func encode(_ text: String) throws -> TextEncoderXLOutput {
        try prompts.output(slot: slot, text: text) { try base.encode(text) }
    }
}

/// When a run's stages end: the first step, the last, and the pictures
/// decoded.
private final class StageClock: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date.now
    private var first: Date?
    private var last: Date?

    func step() {
        lock.withLock {
            let now = Date.now
            if first == nil { first = now }
            last = now
        }
    }

    /// Seconds until the first step ended, stepping after it, and after the last.
    func stages() -> (Double, Double, Double) {
        lock.withLock {
            let end = Date.now
            guard let first, let last else { return (end.timeIntervalSince(started), 0, 0) }
            return (first.timeIntervalSince(started), last.timeIntervalSince(first), end.timeIntervalSince(last))
        }
    }
}
