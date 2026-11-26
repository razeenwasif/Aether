import Foundation

/// What a run on this Mac makes of a graph: the settings Apple's Core ML
/// Stable Diffusion pipeline takes, read from the graph a run would send to
/// forge, or why it can't run here. The pipeline runs one SDXL checkpoint at
/// the size its models were compiled for — text to image, or image to image
/// from a Load Image — with no LoRAs, masks, upscalers or second samplers.
public struct LocalPlan: Sendable, Equatable {
    public enum Scheduler: Sendable, Equatable {
        /// DPM-Solver++ multistep, with Karras sigmas or the usual spacing.
        case dpmSolverMultistep(karras: Bool)
        case pndm
    }

    /// The flow's checkpoint, which a local model must answer to.
    public var checkpoint: String
    /// The Load Checkpoint, which shows the model loading.
    public var loader: String?
    public var prompt: String
    public var negative: String
    public var width: Int
    public var height: Int
    /// Pictures made at once (Empty Latent's batch).
    public var count: Int
    public var steps: Int
    public var cfg: Double
    /// The pipeline's seed is 32 bits: the flow's, modulo 2³².
    public var seed: UInt32
    public var scheduler: Scheduler
    /// The picture image to image starts from: the Load Image's upload.
    public var startingImage: String?
    /// How much of the picture is redrawn (the sampler's denoise).
    public var strength: Double
    /// The sampler, whose progress a run reports.
    public var sampler: String
    /// The nodes whose pictures the run makes: the outputs fed by its decode.
    public var outputs: [String]
    /// Where this Mac's run differs from forge's, in words.
    public var notes: [String]

    /// Why a graph can't run on this Mac.
    public struct Refusal: Error, Equatable, Sendable {
        public var reasons: [String]
        public var message: String { reasons.joined(separator: "; ") }
    }

    /// The node types a local run understands.
    static let understood: Set<String> = ["LoadCheckpoint", "TextEncode", "EmptyLatent", "KSampler", "VAEDecode", "VAEEncode",
                                          "LoadImage", "SaveImage", "PreviewImage"]
    /// What the rest are, for the refusal.
    static let named: [String: String] = [
        "LoadLoRA": "LoRAs", "LoadVAE": "a VAE of its own", "SetLatentMask": "masks (inpainting)", "InvertMask": "masks (inpainting)",
        "UpscaleLatent": "upscaling", "UpscaleImage": "upscaling", "LoadUpscaler": "upscaling",
    ]

    /// The plan for a graph (as a run sends it), for models made at `side`
    /// × `side`, or why there is none.
    public static func make(graphJSON: String, side: Int = 1024) -> Result<LocalPlan, Refusal> {
        guard let graph = try? JSONDecoder().decode(SentGraph.self, from: Data(graphJSON.utf8)) else {
            return .failure(Refusal(reasons: ["the graph can't be read"]))
        }
        var reasons: [String] = []
        let others = Set(graph.nodes.map(\.type)).subtracting(understood)
        let kinds = Set(others.map { named[$0] ?? "\($0) nodes" })
        if !kinds.isEmpty {
            reasons.append("this Mac's Core ML pipeline doesn't do " + kinds.sorted().joined(separator: ", "))
        }
        let samplers = graph.nodes.filter { $0.type == "KSampler" }
        guard samplers.count == 1, let sampler = samplers.first else {
            reasons.append(samplers.isEmpty ? "the graph has no sampler" : "the graph has \(samplers.count) samplers, and this Mac runs one")
            return .failure(Refusal(reasons: reasons))
        }
        let feeding = { (input: String) in graph.source(of: "\(sampler.id):\(input)") }

        let loader = feeding("model").flatMap { $0.type == "LoadCheckpoint" ? $0 : nil }
        let checkpoint = loader?.values["checkpoint"]?.stringValue
        if checkpoint == nil { reasons.append("the sampler's model isn't a Load Checkpoint") }
        guard let positive = feeding("positive"), positive.type == "TextEncode" else {
            reasons.append("the sampler's positive isn't a Text Encode")
            return .failure(Refusal(reasons: reasons))
        }
        let negative = feeding("negative").flatMap { $0.type == "TextEncode" ? $0.values["text"]?.stringValue : nil } ?? ""

        var width = side, height = side, count = 1
        var startingImage: String?
        var notes: [String] = []
        switch feeding("latent") {
        case let latent? where latent.type == "EmptyLatent":
            width = latent.values["width"]?.intValue.map(Int.init) ?? side
            height = latent.values["height"]?.intValue.map(Int.init) ?? side
            count = max(1, latent.values["batch"]?.intValue.map(Int.init) ?? 1)
            if width != side || height != side {
                reasons.append("this Mac's model makes \(side) × \(side) only, and the flow asks for \(width) × \(height)")
            }
        case let latent? where latent.type == "VAEEncode":
            let load = graph.source(of: "\(latent.id):image")
            guard let load, load.type == "LoadImage", let image = load.values["image"]?.stringValue else {
                reasons.append("the picture to start from isn't a Load Image's")
                return .failure(Refusal(reasons: reasons))
            }
            startingImage = image
            notes.append("the picture is scaled to cover \(side) × \(side), the size this Mac's model makes, and cropped to its middle")
        default:
            reasons.append("the sampler's latent is neither an Empty Latent nor a picture's")
        }

        let samplerName = sampler.values["sampler"]?.stringValue ?? "dpmpp_2m"
        let schedule = sampler.values["scheduler"]?.stringValue ?? "normal"
        let scheduler: Scheduler
        switch samplerName {
        case "dpmpp_2m": scheduler = .dpmSolverMultistep(karras: schedule == "karras")
        case "ddim": scheduler = .pndm
        default:
            scheduler = .dpmSolverMultistep(karras: schedule == "karras")
            notes.append("\(samplerName) isn't one of Core ML's samplers, so DPM++ 2M is used")
        }
        if !["normal", "karras"].contains(schedule) {
            notes.append("the \(schedule) schedule isn't Core ML's: \(scheduler == .dpmSolverMultistep(karras: true) ? "Karras" : "its usual spacing") is used")
        }
        let seed = UInt64(clamping: max(0, sampler.values["seed"]?.intValue ?? 0))
        if seed > UInt64(UInt32.max) { notes.append("the seed is taken modulo 2³², as the pipeline's seed is 32 bits") }

        let decodes = graph.nodes.filter { $0.type == "VAEDecode" && graph.source(of: "\($0.id):latent")?.id == sampler.id }
        let outputs = graph.nodes.filter { node in
            ["SaveImage", "PreviewImage"].contains(node.type) && decodes.contains { graph.source(of: "\(node.id):images")?.id == $0.id }
        }
        if outputs.isEmpty { reasons.append("no Save Image or Preview Image shows the sampler's picture") }

        guard reasons.isEmpty, let checkpoint else { return .failure(Refusal(reasons: reasons)) }
        return .success(LocalPlan(
            checkpoint: checkpoint,
            loader: loader?.id,
            prompt: positive.values["text"]?.stringValue ?? "",
            negative: negative,
            width: width, height: height, count: count,
            steps: max(1, sampler.values["steps"]?.intValue.map(Int.init) ?? 30),
            cfg: sampler.values["cfg"]?.doubleValue ?? 6.5,
            seed: UInt32(truncatingIfNeeded: seed),
            scheduler: scheduler,
            startingImage: startingImage,
            strength: startingImage == nil ? 1 : min(1, max(0, sampler.values["denoise"]?.doubleValue ?? 1)),
            sampler: sampler.id,
            outputs: outputs.map(\.id),
            notes: notes))
    }
}

/// A graph as a run sends it, read for planning.
struct SentGraph: Decodable {
    struct Node: Decodable {
        var id: String
        var type: String
        var values: [String: JSONValue]
    }
    struct Link: Decodable {
        var from: String
        var to: String
    }
    var nodes: [Node]
    var links: [Link]

    /// The node feeding the input `port` (`node:input`), if one does.
    func source(of port: String) -> Node? {
        guard let link = links.first(where: { $0.to == port }), let id = link.from.split(separator: ":").first else { return nil }
        return nodes.first { $0.id == String(id) }
    }
}
