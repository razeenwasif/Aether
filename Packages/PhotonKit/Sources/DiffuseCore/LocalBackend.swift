import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Core ML model installed on this Mac: a folder of compiled models, as
/// Apple's Stable Diffusion pipeline loads them (TextEncoder, TextEncoder2,
/// Unet, VAEDecoder and, for image to image, VAEEncoder, with the
/// tokenizer's vocab.json and merges.txt).
public struct LocalModel: Sendable, Equatable, Identifiable {
    public var id: String { folder.path }
    /// What the flow's checkpoint list shows.
    public var name: String
    public var folder: URL
    /// The side of the square pictures its models were compiled for.
    public var side: Int
    /// Whether it has the VAE encoder image to image needs.
    public var takesPictures: Bool
    /// The checkpoints it stands in for: its own name, and forge's names
    /// for the same model (an SDXL base answers to sd_xl_base_1.0).
    public var answersTo: [String]

    public func answers(_ checkpoint: String) -> Bool { answersTo.contains(checkpoint) }
}

/// Where this Mac's models are kept, and what is there.
public enum LocalModels {
    /// `~/Library/Application Support/Photon/Models`, a folder per model.
    public static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Photon/Models", directoryHint: .isDirectory)
    }

    /// Legacy `~/Library/Application Support/Aether/Models` fallback so
    /// already-downloaded models keep working without re-downloading.
    public static var legacyFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Aether/Models", directoryHint: .isDirectory)
    }

    /// The SDXL models in `folder`'s subfolders (or in both `folder` and
    /// `legacyFolder` when `folder` is `nil`, preferring `folder`). A model's
    /// `photon-model.json` (or legacy `aether-model.json`, `{"name", "answersTo"}`),
    /// written when downloaded, names it; without one, its folder does.
    public static func installed(in folder: URL? = nil) -> [LocalModel] {
        let fm = FileManager.default
        let folders = folder.map { [$0] } ?? [Self.folder, Self.legacyFolder]
        var seen: Set<String> = []
        var found: [LocalModel] = []
        for root in folders {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for dir in entries {
                let required = ["TextEncoder2.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]
                guard required.allSatisfy({ fm.fileExists(atPath: dir.appending(path: $0).path) }) else { continue }
                struct Named: Decodable { var name: String; var answersTo: [String]? }
                let metaData = (try? Data(contentsOf: dir.appending(path: "photon-model.json")))
                    ?? (try? Data(contentsOf: dir.appending(path: "aether-model.json")))
                let named = metaData.flatMap { try? JSONDecoder().decode(Named.self, from: $0) }
                let name = named?.name ?? dir.lastPathComponent
                guard seen.insert(name).inserted else { continue }
                found.append(LocalModel(
                    name: name,
                    folder: dir,
                    side: side(of: dir.appending(path: "Unet.mlmodelc")) ?? 1024,
                    takesPictures: fm.fileExists(atPath: dir.appending(path: "VAEEncoder.mlmodelc").path),
                    answersTo: [name] + (named?.answersTo ?? [])))
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// The picture side a compiled U-Net makes: its latent's, times 8.
    static func side(of unet: URL) -> Int? {
        struct Schema: Decodable {
            struct Input: Decodable { var name: String; var shape: String? }
            var inputSchema: [Input]
        }
        guard let data = try? Data(contentsOf: unet.appending(path: "metadata.json")),
              let schema = (try? JSONDecoder().decode([Schema].self, from: data))?.first,
              let shape = schema.inputSchema.first(where: { $0.name == "sample" })?.shape
        else { return nil }
        let numbers = shape.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.last.map { $0 * 8 }
    }
}

/// What makes pictures on this Mac: Apple's Core ML Stable Diffusion
/// pipeline, or a stand-in for tests. `progress` is called after each step
/// with the step and the steps; answering `false` stops the run.
public protocol LocalPipeline: Sendable {
    /// Load `model` if it isn't loaded: slow the first time on a Mac.
    func prepare(_ model: LocalModel) throws
    func generate(_ plan: LocalPlan, model: LocalModel, startingImage: CGImage?,
                  progress: @escaping @Sendable (Int, Int) -> Bool) throws -> [CGImage]
}

public extension LocalPipeline {
    func prepare(_ model: LocalModel) throws {}
}

/// Image generation on this Mac, behind the same face as Nexus's gateway:
/// a graph goes in, a run's events come out, and its pictures are PNGs with
/// the graph written into them as forge writes it. One run at a time, as
/// one SDXL is all 16 GB holds.
public actor LocalBackend: ImageBackend {
    public enum Failure: LocalizedError {
        case noModel(String)
        case notRunnable(String)
        case unknownRun(String)
        case stopped

        public var errorDescription: String? {
            switch self {
            case .noModel(let checkpoint): "No model on this Mac answers to \(checkpoint)."
            case .notRunnable(let why): "This flow can't run on this Mac: \(why)."
            case .unknownRun(let run): "There is no run \(run) on this Mac."
            case .stopped: "Stopped."
            }
        }
    }

    private struct Job {
        var plan: LocalPlan
        var graphJSON: String
        var cancelled = false
    }

    private let pipeline: any LocalPipeline
    private let modelsFolder: URL
    private var uploads: [String: Data] = [:]
    private var jobs: [String: Job] = [:]
    private var images: [String: Data] = [:]
    /// Each run's stop, which its worker reads between steps.
    private var stops: [String: CancelFlag] = [:]
    private var made = 0
    /// The run working now: the next waits for it.
    private var working: Task<Void, Never>?

    public init(pipeline: any LocalPipeline, modelsFolder: URL = LocalModels.folder) {
        self.pipeline = pipeline
        self.modelsFolder = modelsFolder
    }

    public nonisolated var displayName: String { "This Mac" }

    public var models: [LocalModel] { LocalModels.installed(in: modelsFolder) }

    public func health() async -> Health {
        let models = self.models
        guard let first = models.first else {
            return Health(state: .offline, url: nil, ms: nil, status: nil,
                          message: "No image model on this Mac yet: download one to run flows here.")
        }
        let names = models.map(\.name).joined(separator: ", ")
        return Health(state: .serving, url: first.folder.path, ms: 0, status: nil, message: "This Mac · \(names) (Core ML)")
    }

    /// The built-in catalogue, its checkpoints this Mac's models.
    public func library() async throws -> NodeLibrary {
        let builtIn = NodeLibrary.builtIn()
        let checkpoints = models.flatMap(\.answersTo)
        let lists: [String: [[String: String]]] = ["checkpoints": checkpoints.map { ["name": $0] }, "loras": [], "vaes": [], "upscalers": []]
        let models = String(decoding: try JSONSerialization.data(withJSONObject: lists), as: UTF8.self)
        return try NodeLibrary(catalogueJSON: builtIn.core.json(), modelsJSON: models, source: .builtIn)
    }

    public func upload(_ picture: Data) async throws -> String {
        made += 1
        let id = "local-upload-\(made).png"
        uploads[id] = picture
        return id
    }

    public func run(graphJSON: String) async throws -> Queued {
        let plan: LocalPlan
        switch LocalPlan.make(graphJSON: graphJSON, side: models.first?.side ?? 1024) {
        case .success(let made): plan = made
        case .failure(let refusal): throw Failure.notRunnable(refusal.message)
        }
        guard let model = models.first(where: { $0.answers(plan.checkpoint) }) else { throw Failure.noModel(plan.checkpoint) }
        if plan.startingImage != nil && !model.takesPictures {
            throw Failure.notRunnable("\(model.name) has no image encoder, which image to image needs")
        }
        made += 1
        let run = "local-run-\(made)"
        jobs[run] = Job(plan: plan, graphJSON: graphJSON)
        stops[run] = CancelFlag()
        return Queued(run: run, position: working == nil ? 0 : 1)
    }

    public nonisolated func events(run: String) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.perform(run, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(_ id: String) async throws -> Data {
        guard let data = images[id] else { throw Failure.unknownRun(id) }
        return data
    }

    public func cancel(run: String) async throws {
        jobs[run]?.cancelled = true
        stops[run]?.cancel()
    }

    private func isCancelled(_ run: String) -> Bool { jobs[run]?.cancelled ?? true }

    private func perform(_ run: String, into continuation: AsyncThrowingStream<RunEvent, Error>.Continuation) async {
        guard let job = jobs[run] else {
            continuation.finish(throwing: Failure.unknownRun(run))
            return
        }
        // One at a time: wait for the run before this one.
        let before = working
        let mine = Task<Void, Never> {
            await before?.value
            await self.work(run, job: job, into: continuation)
        }
        working = mine
        await mine.value
        if working == mine { working = nil }
    }

    private func work(_ run: String, job: Job, into continuation: AsyncThrowingStream<RunEvent, Error>.Continuation) async {
        let started = Date.now
        let plan = job.plan
        guard let model = models.first(where: { $0.answers(plan.checkpoint) }) else {
            continuation.yield(.error(id: nil, error: "model", message: Failure.noModel(plan.checkpoint).localizedDescription))
            continuation.finish()
            return
        }
        if isCancelled(run) {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }
        continuation.yield(.started)
        let starting = plan.startingImage.flatMap { uploads[$0] }.flatMap(Self.picture(from:))
        let pipeline = self.pipeline
        let flags = stops[run] ?? CancelFlag()
        // The model, loaded on the Load Checkpoint's card: slow only the first time.
        if let loader = plan.loader { continuation.yield(.node(id: loader, state: .running)) }
        let prepared: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try pipeline.prepare(model) }
        }.value
        if case .failure(let error) = prepared {
            continuation.yield(.error(id: plan.loader, error: "model", message: "\(model.name) couldn’t be loaded: \(error.localizedDescription)"))
            continuation.finish()
            return
        }
        if let loader = plan.loader { continuation.yield(.node(id: loader, state: .done)) }
        continuation.yield(.node(id: plan.sampler, state: .running))
        let made: Result<[CGImage], Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try pipeline.generate(plan, model: model, startingImage: starting) { step, steps in
                    continuation.yield(.progress(id: plan.sampler, step: step, steps: steps))
                    return !flags.isCancelled
                }
            }
        }.value
        if flags.isCancelled || isCancelled(run) {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }
        switch made {
        case .failure(let error):
            continuation.yield(.error(id: plan.sampler, error: "pipeline", message: error.localizedDescription))
        case .success(let pictures):
            continuation.yield(.node(id: plan.sampler, state: .done))
            for (index, picture) in pictures.enumerated() {
                guard let png = Self.png(picture, graph: job.graphJSON) else { continue }
                for output in plan.outputs {
                    let id = "\(run)_\(output)_\(index)"
                    images[id] = png
                    continuation.yield(.image(id: output, image: id, index: index, width: picture.width, height: picture.height))
                }
            }
            continuation.yield(.done(seconds: (Date.now.timeIntervalSince(started) * 10).rounded() / 10))
        }
        continuation.finish()
    }

    /// A picture read from an upload's bytes.
    static func picture(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A picture as a PNG with the graph that made it written in, as forge
    /// writes it: a `proton-flow` text chunk after the IHDR.
    static func png(_ picture: CGImage, graph: String) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PNGText.adding(key: "proton-flow", text: #"{"graph": \#(graph)}"#, to: out as Data)
    }
}

/// A flag a run's worker reads between steps.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Text chunks in PNGs.
enum PNGText {
    /// `png` with a `tEXt` chunk of `key` and `text` after its IHDR; as it
    /// is when it isn't a PNG. tEXt is Latin-1, so the text should be ASCII
    /// (JSON escapes the rest).
    static func adding(key: String, text: String, to png: Data) -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard png.count > 33, png.prefix(8).elementsEqual(signature) else { return png }
        let ihdrLength = Int(png[8]) << 24 | Int(png[9]) << 16 | Int(png[10]) << 8 | Int(png[11])
        let afterIHDR = 8 + 12 + ihdrLength
        let body = Data(key.utf8) + [0] + Data(text.utf8)
        let typed = Data("tEXt".utf8) + body
        var chunk = Data()
        chunk.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        chunk.append(typed)
        chunk.append(contentsOf: withUnsafeBytes(of: crc32(typed).bigEndian, Array.init))
        return png.prefix(afterIHDR) + chunk + png.dropFirst(afterIHDR)
    }

    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
