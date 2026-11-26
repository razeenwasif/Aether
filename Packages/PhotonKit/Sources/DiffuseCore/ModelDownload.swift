import Foundation
import Observation

/// A model this Mac can download: Apple's compiled Core ML files, by path
/// and size, and the checkpoints it stands in for.
public struct LocalModelOffer: Sendable, Identifiable, Equatable {
    public struct File: Sendable, Equatable {
        public var path: String
        public var size: Int64
        public init(_ path: String, _ size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public var id: String { name }
    public var name: String
    public var base: URL
    public var files: [File]
    public var answersTo: [String]
    public var source: String
    public var total: Int64 { files.reduce(0) { $0 + $1.size } }

    public init(name: String, base: URL, files: [File], answersTo: [String], source: String) {
        self.name = name
        self.base = base
        self.files = files
        self.answersTo = answersTo
        self.source = source
    }

    /// Apple's 4.5-bit palettized SDXL base, compiled for Swift: 3.36 GB,
    /// what fits a 16 GB Mac with room to spare (RESEARCH_PLAN.md §10a).
    public static let sdxlBase4Bit: LocalModelOffer = {
        let parts: [(String, [Int64])] = [
            ("TextEncoder", [207, 825, 2_710, 188_382, 246_145_536]),
            ("TextEncoder2", [207, 825, 2_711, 491_456, 1_389_367_424]),
            ("Unet", [243, 1_338, 4_431, 2_491_351, 1_450_049_728]),
            ("VAEDecoder", [207, 773, 2_467, 168_425, 197_977_216]),
            ("VAEEncoder", [207, 783, 2_494, 138_263, 68_338_112]),
        ]
        let inside = ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
        var files = parts.flatMap { part, sizes in zip(inside, sizes).map { File("\(part).mlmodelc/\($0)", $1) } }
        files += [File("merges.txt", 524_657), File("vocab.json", 862_328)]
        return LocalModelOffer(
            name: "SDXL base (4.5-bit)",
            base: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization/resolve/main/coreml-stable-diffusion-xl-base_mbp_4_50_palettized/compiled")!,
            files: files,
            answersTo: ["sd_xl_base_1.0.safetensors", "sd_xl_base_1.0_0.9vae.safetensors"],
            source: "huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization, coreml-stable-diffusion-xl-base_mbp_4_50_palettized/compiled")
    }()
}

/// A model downloading into the Models folder: each file checked against
/// its size, into `<name>.partial`, renamed when all are there, so a
/// half-done download is never taken for a model. Started again, it keeps
/// the files already fetched.
@MainActor
@Observable
public final class ModelDownload {
    public enum Phase: Equatable, Sendable {
        case idle
        case fetching(done: Int64, total: Int64)
        case installed(URL)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public var isFetching: Bool { if case .fetching = phase { true } else { false } }

    public func start(_ offer: LocalModelOffer, into folder: URL = LocalModels.folder, configuration: URLSessionConfiguration = .default) {
        guard task == nil else { return }
        phase = .fetching(done: 0, total: offer.total)
        task = Task {
            let outcome = await Self.fetch(offer, into: folder, configuration: configuration) { done in
                Task { @MainActor in
                    if case .fetching = self.phase { self.phase = .fetching(done: done, total: offer.total) }
                }
            }
            switch outcome {
            case .success(let installed): phase = .installed(installed)
            case .failure(let error): phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    struct SizeMismatch: LocalizedError {
        var path: String
        var got: Int64
        var expected: Int64
        var errorDescription: String? { "\(path) came as \(got) bytes, not \(expected): try again" }
    }

    struct Refused: LocalizedError {
        var path: String
        var status: Int
        var errorDescription: String? { "\(path) wasn’t given (HTTP \(status))" }
    }

    nonisolated static func fetch(_ offer: LocalModelOffer, into folder: URL, configuration: URLSessionConfiguration,
                                  progress: @escaping @Sendable (Int64) -> Void) async -> Result<URL, Error> {
        let fm = FileManager.default
        let destination = folder.appending(path: offer.name, directoryHint: .isDirectory)
        if fm.fileExists(atPath: destination.path) { return .success(destination) }
        let partial = folder.appending(path: offer.name + ".partial", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            var done: Int64 = 0
            for file in offer.files {
                try Task.checkCancellation()
                let out = partial.appending(path: file.path)
                if let size = (try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int64, size == file.size {
                    done += file.size
                    progress(done)
                    continue
                }
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = done
                try await FileFetch.get(offer.base.appending(path: file.path), to: out, configuration: configuration) { written in
                    progress(before + written)
                }
                let size = (try fm.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? -1
                guard size == file.size else {
                    try? fm.removeItem(at: out)
                    throw SizeMismatch(path: file.path, got: size, expected: file.size)
                }
                done += file.size
                progress(done)
            }
            let named = try JSONSerialization.data(withJSONObject: ["name": offer.name, "answersTo": offer.answersTo, "source": offer.source],
                                                   options: [.prettyPrinted, .sortedKeys])
            try named.write(to: partial.appending(path: "photon-model.json"))
            try fm.moveItem(at: partial, to: destination)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }
}

/// One file fetched to disk, with its bytes counted as they come.
private final class FileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func get(_ url: URL, to destination: URL, configuration: URLSessionConfiguration,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fetch = FileFetch(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetch.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = ModelDownload.Refused(path: destination.lastPathComponent, status: http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

/// Where a run goes: forge through Nexus, or this Mac's Core ML pipeline.
public enum RunPlace: String, Sendable, CaseIterable {
    /// forge while it's serving, as it's far quicker (a 4090 against an M2
    /// Pro); this Mac when forge can't be reached and this Mac can run the flow.
    case automatic
    case local
    case forge

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .local: "This Mac"
        case .forge: "forge"
        }
    }
}

/// Where a flow's next run goes, and why.
public struct RunRoute: Equatable, Sendable {
    public var local: Bool
    public var why: String

    /// For a flow set to `place`, whose run sends `graphJSON` (`nil` when
    /// problems stop it), with `models` on this Mac and forge as `forge`
    /// says it is.
    public static func decide(_ place: RunPlace, graphJSON: String?, models: [LocalModel], forge: HealthState) -> RunRoute {
        switch place {
        case .forge:
            return RunRoute(local: false, why: "Set to run on forge.")
        case .local:
            return RunRoute(local: true, why: "Set to run on this Mac.")
        case .automatic:
            switch forge {
            case .serving:
                return RunRoute(local: false, why: "On forge, which is serving.")
            case .looking:
                return RunRoute(local: false, why: "On forge, once it answers.")
            case .offline, .badKey, .noKey, .unreachable, .failing:
                break
            }
            // forge can't be reached: this Mac, if it can run the flow.
            switch local(graphJSON: graphJSON, models: models) {
            case .success(let model):
                return RunRoute(local: true, why: "On this Mac, with \(model.name): forge can’t be reached.")
            case .failure(let why):
                return RunRoute(local: false, why: "On forge, though it can’t be reached: \(why).")
            }
        }
    }

    /// The model on this Mac that can run a graph, or why none can.
    static func local(graphJSON: String?, models: [LocalModel]) -> Result<LocalModel, Reason> {
        guard let first = models.first else { return .failure(Reason("there’s no image model on this Mac")) }
        guard let graphJSON else { return .success(first) }
        switch LocalPlan.make(graphJSON: graphJSON, side: first.side) {
        case .failure(let refusal):
            return .failure(Reason(refusal.message))
        case .success(let plan):
            guard let model = models.first(where: { $0.answers(plan.checkpoint) }) else {
                return .failure(Reason("no model on this Mac stands in for \(plan.checkpoint)"))
            }
            if plan.startingImage != nil && !model.takesPictures {
                return .failure(Reason("\(model.name) can’t start from a picture"))
            }
            return .success(model)
        }
    }

    struct Reason: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
