import DiffuseBridge
import Foundation
import Testing
@testable import DiffuseCore

/// A test key: never the person's, which stays in their keychain.
private func testKey(_ byte: UInt8 = 7) throws -> SealKey {
    try SealKey(key: Data(repeating: byte, count: 32))
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aether-sealed-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Whether the file at `url` is sealed as Proton seals: its magic, and none
/// of `plain` showing through.
private func isSealedOnDisk(_ url: URL, hiding plain: String) throws -> Bool {
    let bytes = try Data(contentsOf: url)
    return bytes.starts(with: Data("PXSEAL1\0".utf8)) && bytes.range(of: Data(plain.utf8)) == nil
}

/// The lighthouse flow written sealed, as Proton leaves it: only
/// `lighthouse.flow.json.sealed` on disk. Answers the plain file's place.
private func sealedLighthouse(in dir: URL, key: SealKey) throws -> URL {
    let plain = dir.appending(path: "lighthouse.flow.json")
    _ = try writeFile(path: plain.path, bytes: Data(contentsOf: Fixture.url("lighthouse.flow.json")), key: key)
    return plain
}

@MainActor
struct SealedTests {
    @Test func aSealedFlowOpensWithTheKeyAndStaysSealed() throws {
        let dir = try scratch()
        let key = try testKey()
        let plain = try sealedLighthouse(in: dir, key: key)
        #expect(SealedFiles.isSealed(plain) && !FileManager.default.fileExists(atPath: plain.path))

        // Chosen by its sealed name, as an open panel gives it.
        let editor = try FlowEditor.open(SealedFiles.sealed(plain), library: Fixture.library(), key: key)
        #expect(editor.isSealed && editor.url == plain && editor.name == "lighthouse")
        #expect(editor.apply([.note("a private note")]) != nil)
        try editor.save()
        #expect(try isSealedOnDisk(SealedFiles.sealed(plain), hiding: "a private note"))
        #expect(!FileManager.default.fileExists(atPath: plain.path))

        let reopened = try FlowEditor.open(plain, library: Fixture.library(), key: key)
        #expect(reopened.flow.note == "a private note")
    }

    @Test func aSealedFlowWontOpenWithoutTheRightKey() throws {
        let dir = try scratch()
        let plain = try sealedLighthouse(in: dir, key: testKey())
        let refused = #expect(throws: DiffuseError.self) { try FlowEditor.open(plain, library: Fixture.library()) }
        #expect(refused.map(describe)?.contains("unlock Diffuse") == true)
        #expect(throws: DiffuseError.self) { try FlowEditor.open(plain, library: Fixture.library(), key: testKey(8)) }
    }

    @Test func aPlainFlowStaysPlainWithTheKey() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library(), key: testKey())
        #expect(!editor.isSealed && editor.sealKey == nil)
        try editor.save()
        #expect(!SealedFiles.isSealed(editor.url))
    }

    @Test func saveAsKeepsASealedFlowSealed() throws {
        let dir = try scratch()
        let key = try testKey()
        let editor = try FlowEditor.open(sealedLighthouse(in: dir, key: key), library: Fixture.library(), key: key)
        let copy = dir.appending(path: "copy.flow.json")
        try editor.save(as: copy)
        #expect(editor.url == copy && SealedFiles.isSealed(copy))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aSealedPicturesGraphOpensAsASealedFlow() throws {
        let library = try Fixture.library()
        let graph = try FlowEditor.open(Fixture.lighthouse(), library: library).graphJSON()
        let url = try scratch().appending(path: "lighthouse_0001.flow.json")
        let editor = try FlowEditor.create(at: url, fromGraph: graph, library: library, sealedWith: testKey())
        #expect(editor.isSealed)
        try editor.save()
        #expect(SealedFiles.isSealed(url) && !FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theGalleryListsSealedPicturesAndReadsThemWithTheKey() async throws {
        let root = try scratch()
        let key = try testKey()
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let png = PNGFixture.head(width: 1344, height: 768, flow: #"{"graph": \#(try editor.graphJSON())}"#)
        let folder = root.appending(path: "outputs/lighthouse", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try writeFile(path: folder.appending(path: "lighthouse_0002.png").path, bytes: png, key: key)
        // Left plain from before Proton sealed it, beside its sealed twin.
        try png.write(to: folder.appending(path: "lighthouse_0001.png"))
        _ = try writeFile(path: folder.appending(path: "lighthouse_0001.png").path, bytes: png, key: key)

        let gallery = Gallery()
        await gallery.refresh(roots: [root])
        #expect(gallery.pictures.count == 2 && gallery.sealedCount == 2)
        #expect(Set(gallery.pictures.map(\.name)) == ["lighthouse_0001.png", "lighthouse_0002.png"])

        let sealed = try #require(gallery.pictures.first)
        #expect(await gallery.head(for: sealed.url) == nil)
        gallery.key = key
        let head = try #require(await gallery.head(for: sealed.url))
        #expect(head.width == 1344 && head.made?.prompt?.isEmpty == false)
        gallery.key = nil
        #expect(gallery.heads.isEmpty)
    }

    @Test func outputsAreNumberedPastSealedOnes() throws {
        let folder = try scratch()
        try Data().write(to: folder.appending(path: "image_0004.png.sealed"))
        try Data().write(to: folder.appending(path: "image_0002.png"))
        #expect(OutputNaming.next(in: folder, prefix: "image").lastPathComponent == "image_0005.png")
    }

    @Test func aSealedFlowsRunSealsWhatItMakes() async throws {
        let dir = try scratch()
        let key = try testKey()
        let editor = try FlowEditor.open(sealedLighthouse(in: dir, key: key), library: Fixture.library(), key: key)
        let output = try #require(editor.flow.nodes.first { editor.library.catalogue.node($0.type)?.isOutput == true })
        let picture = PNGFixture.head(width: 64, height: 64, flow: nil)
        let queue = RunQueue(backend: OneImageBackend(node: output.id, picture: picture))

        queue.run(editor)
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(run.phase == .done(seconds: 0.1))

        let file = try #require(run.outputs.first?.file)
        #expect(file.lastPathComponent.hasSuffix(".png.sealed"))
        #expect(file.deletingLastPathComponent().path.hasSuffix("outputs/lighthouse"))
        #expect(try Data(contentsOf: file).starts(with: Data("PXSEAL1\0".utf8)))
        #expect(try readFile(path: file.path, key: key) == picture)
    }
}

/// A backend whose every run makes one picture at `node`, at once.
private struct OneImageBackend: ImageBackend {
    let node: String
    let picture: Data
    var displayName: String { "One image" }

    func health() async -> Health { .looking }
    func library() async throws -> NodeLibrary { try Fixture.library() }
    func run(graphJSON: String) async throws -> Queued { Queued(run: "run1", position: 0) }
    func events(run: String) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.image(id: node, image: "run1_\(node)", index: 0, width: 64, height: 64))
            continuation.yield(.done(seconds: 0.1))
            continuation.finish()
        }
    }
    func image(_ id: String) async throws -> Data { picture }
    func upload(_ picture: Data) async throws -> String { "upload1" }
    func cancel(run: String) async throws {}
}
