// Times image generation on this Mac: the text encoders on each compute
// unit, and whole runs through Photon's Core ML pipeline, with the prompt
// cache on or off. Uses the first model in Photon's Models folder.
//
//   swift run -c release photon-local-bench encoders --on ane
//   swift run -c release photon-local-bench runs --on gpu --steps 10 --runs 3 [--no-cache]
import CoreGraphics
import CoreML
import DiffuseCore
import DiffuseLocal
import Foundation
import StableDiffusion

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    arguments.firstIndex(of: "--\(name)").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
func units(_ name: String?) -> MLComputeUnits {
    switch name ?? "gpu" {
    case "ane": .cpuAndNeuralEngine
    case "cpu": .cpuOnly
    case "all": .all
    default: .cpuAndGPU
    }
}
func seconds(_ since: Date) -> String { String(format: "%.2f s", Date.now.timeIntervalSince(since)) }

let prompt = "a lighthouse at dusk, oil painting"
let negative = "blurry, low contrast, text, watermark"
guard let model = LocalModels.installed().first else {
    print("no model in \(LocalModels.folder.path)")
    exit(1)
}
let on = units(option("on"))
print("model: \(model.name) · text encoders on \(option("on") ?? "gpu")")

switch arguments.first {
case "encoders":
    // The two encoders alone, loaded and run as the pipeline runs them.
    let at = { (name: String) in model.folder.appending(path: name) }
    let config = MLModelConfiguration()
    config.computeUnits = on
    let tokenizer = try BPETokenizer(mergesAt: at("merges.txt"), vocabularyAt: at("vocab.json"))
    let tokenizer2 = try BPETokenizer(mergesAt: at("merges.txt"), vocabularyAt: at("vocab.json"), padToken: "!")
    for (name, encoder) in [("TextEncoder", TextEncoderXL(tokenizer: tokenizer, modelAt: at("TextEncoder.mlmodelc"), configuration: config)),
                            ("TextEncoder2", TextEncoderXL(tokenizer: tokenizer2, modelAt: at("TextEncoder2.mlmodelc"), configuration: config))] {
        var started = Date.now
        try encoder.loadResources()
        print("\(name): load \(seconds(started))")
        for round in 1...3 {
            started = Date.now
            _ = try encoder.encode(prompt)
            _ = try encoder.encode(negative)
            print("\(name): prompt and negative, round \(round): \(seconds(started))")
        }
        encoder.unloadResources()
    }

case "runs":
    let steps = Int(option("steps") ?? "10") ?? 10
    let runs = Int(option("runs") ?? "2") ?? 2
    let pipeline = CoreMLPipeline(textEncoders: on, cachesPrompts: !arguments.contains("--no-cache"))
    let graph = """
        {"nodes": [
          {"id": "1", "type": "LoadCheckpoint", "values": {"checkpoint": "\(model.answersTo.last ?? model.name)"}},
          {"id": "2", "type": "TextEncode", "values": {"text": "\(prompt)"}},
          {"id": "3", "type": "TextEncode", "values": {"text": "\(negative)"}},
          {"id": "4", "type": "EmptyLatent", "values": {"width": \(model.side), "height": \(model.side), "batch": 1}},
          {"id": "5", "type": "KSampler", "values": {"seed": 42, "steps": \(steps), "cfg": 6.5, "sampler": "dpmpp_2m", "scheduler": "karras", "denoise": 1}},
          {"id": "6", "type": "VAEDecode", "values": {}},
          {"id": "7", "type": "SaveImage", "values": {"prefix": "bench"}}],
         "links": [
          {"from": "1:model", "to": "5:model"}, {"from": "1:clip", "to": "2:clip"}, {"from": "1:clip", "to": "3:clip"},
          {"from": "2:conditioning", "to": "5:positive"}, {"from": "3:conditioning", "to": "5:negative"},
          {"from": "4:latent", "to": "5:latent"}, {"from": "5:latent", "to": "6:latent"}, {"from": "1:vae", "to": "6:vae"},
          {"from": "6:image", "to": "7:images"}]}
        """
    let plan = try LocalPlan.make(graphJSON: graph, side: model.side).get()
    print("run  load     encode (kept)   first step  steps     decode   total    pixels")
    for run in 1...runs {
        let pictures = try pipeline.generate(plan, model: model, startingImage: nil) { _, _ in true }
        let t = pipeline.lastRun!
        // FNV-1a over the pixels: the same picture, the same number.
        let bytes = pictures.first.flatMap { $0.dataProvider?.data as Data? } ?? Data()
        let hash = bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        print(String(format: "%-4d %-8@ %5.1f s (%d/4)    %5.1f s     %5.1f s   %5.1f s  %5.1f s  %016llx",
                     run, t.load.map { String(format: "%.1f s", $0) } ?? "–" as NSString as String, t.encode, t.keptEncodings,
                     t.firstStep, t.steps, t.decode, t.total, hash))
    }

default:
    print("usage: photon-local-bench encoders --on gpu|ane|cpu|all")
    print("       photon-local-bench runs --on gpu|ane|cpu|all [--steps N] [--runs N] [--no-cache]")
}
