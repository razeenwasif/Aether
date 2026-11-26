import Foundation
import Testing
@testable import DiffuseCore

/// Answers requests from a table of paths to bodies, as a server would,
/// counting what was asked for. Nothing leaves the Mac.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    static let lock = NSLock()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.lock.withLock {
            Self.asked.append(path)
            return Self.bodies.first { path.hasSuffix($0.key) }?.value
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ModelDownloadTests {
    private func offer(_ files: [(String, String)]) -> LocalModelOffer {
        LocalModelOffer(name: "Tiny SDXL", base: URL(string: "https://models.test/tiny")!,
                        files: files.map { .init($0.0, Int64($0.1.utf8.count)) }, answersTo: ["sd_xl_base_1.0.safetensors"], source: "a test")
    }

    private let files = [
        ("TextEncoder2.mlmodelc/weights/weight.bin", "encoder"),
        ("Unet.mlmodelc/metadata.json", #"[{"inputSchema": [{"name": "sample", "shape": "[2, 4, 128, 128]"}]}]"#),
        ("VAEDecoder.mlmodelc/weights/weight.bin", "decoder"),
        ("vocab.json", "{}"),
        ("merges.txt", "#"),
    ]

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aModelComesWholeAndIsFoundAsAModel() async throws {
        StubServer.bodies = Dictionary(uniqueKeysWithValues: files.map { ($0.0, Data($0.1.utf8)) })
        StubServer.asked = []
        let folder = try scratch()
        let seen = Seen()
        let result = await ModelDownload.fetch(offer(files), into: folder, configuration: StubServer.configuration()) { seen.add($0) }
        let installed = try result.get()
        #expect(installed.lastPathComponent == "Tiny SDXL")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Tiny SDXL.partial").path))
        let model = try #require(LocalModels.installed(in: folder).first)
        #expect(model.name == "Tiny SDXL" && model.side == 1024 && model.answers("sd_xl_base_1.0.safetensors"))
        #expect(seen.last == offer(files).total)
    }

    @Test func aShortFileStopsItAndAnotherGoKeepsWhatCame() async throws {
        var bodies = Dictionary(uniqueKeysWithValues: files.map { ($0.0, Data($0.1.utf8)) })
        bodies["VAEDecoder.mlmodelc/weights/weight.bin"] = Data("dec".utf8)
        StubServer.bodies = bodies
        StubServer.asked = []
        let folder = try scratch()
        let first = await ModelDownload.fetch(offer(files), into: folder, configuration: StubServer.configuration()) { _ in }
        #expect(throws: (any Error).self) { try first.get() }
        #expect(LocalModels.installed(in: folder).isEmpty, "a half-done download isn't a model")

        StubServer.bodies["VAEDecoder.mlmodelc/weights/weight.bin"] = Data("decoder".utf8)
        StubServer.asked = []
        _ = try await ModelDownload.fetch(offer(files), into: folder, configuration: StubServer.configuration()) { _ in }.get()
        #expect(!StubServer.asked.contains { $0.hasSuffix("TextEncoder2.mlmodelc/weights/weight.bin") }, "a file already fetched isn't fetched again")
        #expect(LocalModels.installed(in: folder).count == 1)
    }

    @Test func aFileTheServerWontGiveSaysSo() async throws {
        StubServer.bodies = [:]
        let result = await ModelDownload.fetch(offer(files), into: try scratch(), configuration: StubServer.configuration()) { _ in }
        #expect(throws: (any Error).self) { try result.get() }
        if case .failure(let error) = result { #expect(error.localizedDescription.contains("404")) }
    }

    @Test func theOfferedSDXLIsApplesCompiledFilesAndNoMore() {
        let offer = LocalModelOffer.sdxlBase4Bit
        #expect(offer.files.count == 27)
        #expect(offer.total == 3_356_763_306, "the compiled folder's files, no zips and no packages")
        #expect(offer.files.allSatisfy { $0.path.hasPrefix("TextEncoder") || $0.path.hasPrefix("Unet") || $0.path.hasPrefix("VAE") || $0.path.hasSuffix(".json") || $0.path.hasSuffix(".txt") })
    }
}

@MainActor
struct RunRouteTests {
    private func model(answering checkpoint: String = "sd_xl_base_1.0.safetensors", pictures: Bool = true) -> LocalModel {
        LocalModel(name: "SDXL base (4.5-bit)", folder: URL(fileURLWithPath: "/models/sdxl"), side: 1024, takesPictures: pictures,
                   answersTo: ["SDXL base (4.5-bit)", checkpoint])
    }

    @Test func automaticRunsOnForgeWhileItServes() throws {
        let graph = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library()).graphJSON()
        let serving = RunRoute.decide(.automatic, graphJSON: graph, models: [model()], forge: .serving)
        #expect(!serving.local && serving.why.contains("serving"), "forge is far quicker, so it goes first")
        #expect(!RunRoute.decide(.automatic, graphJSON: graph, models: [model()], forge: .looking).local, "still looking isn't unreachable")
    }

    @Test func automaticRunsHereOnlyWhenForgeCantBeReached() throws {
        let graph = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library()).graphJSON()
        for down in [HealthState.unreachable, .offline, .failing, .noKey, .badKey] {
            let here = RunRoute.decide(.automatic, graphJSON: graph, models: [model()], forge: down)
            #expect(here.local && here.why.contains("can’t be reached"), "\(down)")
        }
        let none = RunRoute.decide(.automatic, graphJSON: graph, models: [], forge: .unreachable)
        #expect(!none.local && none.why.contains("no image model"))
        let other = RunRoute.decide(.automatic, graphJSON: graph, models: [model(answering: "illustrious.safetensors")], forge: .unreachable)
        #expect(!other.local && other.why.contains("sd_xl_base"))

        let hires = try FlowEditor.create(at: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).flow.json"),
                                          template: "hiresFix", library: Fixture.library()).graphJSON()
        let refused = RunRoute.decide(.automatic, graphJSON: hires, models: [model()], forge: .unreachable)
        #expect(!refused.local && refused.why.contains("upscaling"))
    }

    @Test func aFlowSetToAPlaceGoesThere() throws {
        let graph = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library()).graphJSON()
        #expect(!RunRoute.decide(.forge, graphJSON: graph, models: [model()], forge: .unreachable).local)
        #expect(RunRoute.decide(.local, graphJSON: graph, models: [], forge: .serving).local, "set to this Mac, the run says why it can't")
    }
}

/// Progress seen, in order.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ value: Int64) { lock.withLock { values.append(value) } }
    var last: Int64? { lock.withLock { values.last } }
}

struct GatewaySettingsTests {
    @Test func protonsNestedAddressesAreRead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-gateway-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proton = dir.appending(path: "settings.json")
        let defaults = try #require(UserDefaults(suiteName: "aether-gateway-\(UUID().uuidString)"))

        try Data(#"{"diffuse": {"gateway": "http://192.168.1.5:7420/img/v1", "gatewayAway": "http://100.64.0.5:7420/img/v1"}}"#.utf8).write(to: proton)
        let nested = GatewaySettings.current(defaults: defaults, proton: proton)
        #expect(nested.home == "http://192.168.1.5:7420/img/v1" && nested.away == "http://100.64.0.5:7420/img/v1")

        try Data(#"{"diffuse.gateway": "http://flat:7420/img/v1"}"#.utf8).write(to: proton)
        #expect(GatewaySettings.current(defaults: defaults, proton: proton).home == "http://flat:7420/img/v1")

        try Data(#"{"research": {}}"#.utf8).write(to: proton)
        #expect(GatewaySettings.current(defaults: defaults, proton: proton).home == GatewaySettings.defaultHome)

        defaults.set("http://saved:7420/img/v1", forKey: "diffuse.gateway")
        #expect(GatewaySettings.current(defaults: defaults, proton: proton).home == "http://saved:7420/img/v1", "Photon's own setting comes first")
    }
}
