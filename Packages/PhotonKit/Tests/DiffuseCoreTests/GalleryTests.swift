import Foundation
import Testing
@testable import DiffuseCore

/// A PNG's head as forge writes it: IHDR, then the graph a run sent as a
/// `proton-flow` tEXt chunk, before any pixels. The core reads only the head,
/// so no pixels follow.
enum PNGFixture {
    static func head(width: UInt32, height: UInt32, flow: String?) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(bigEndian: width)
        ihdr.append(bigEndian: height)
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        if let flow { data.append(chunk("tEXt", Data("proton-flow".utf8) + [0] + Data(flow.utf8))) }
        data.append(chunk("IEND", Data()))
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func chunk(_ kind: String, _ body: Data) -> Data {
        var out = Data()
        out.append(bigEndian: UInt32(body.count))
        let typed = Data(kind.utf8) + body
        out.append(typed)
        out.append(bigEndian: crc32(typed))
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aether-gallery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
struct GalleryTests {
    @Test func readsWhatMadeAPicture() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let graph = try editor.graphJSON()
        let url = try scratch().appending(path: "outputs/lighthouse/lighthouse_0001.png")
        try PNGFixture.write(PNGFixture.head(width: 1344, height: 768, flow: #"{"graph": \#(graph)}"#), to: url)

        let head = try #require(PictureHead.read(url))
        #expect(head.width == 1344 && head.height == 768)
        let made = try #require(head.made)
        let sampler = try #require(editor.flow.nodes.first { $0.type == "KSampler" })
        #expect(made.seed == sampler.values["seed"]?.intValue.map(UInt64.init))
        #expect(made.steps == sampler.values["steps"]?.intValue.map(Int.init))
        #expect(made.prompt?.isEmpty == false)
        #expect(made.checkpoint != nil)
    }

    @Test func aPictureWithoutAGraphStillHasItsSize() throws {
        let url = try scratch().appending(path: "plain.png")
        try PNGFixture.write(PNGFixture.head(width: 64, height: 32, flow: nil), to: url)
        let head = try #require(PictureHead.read(url))
        #expect(head.width == 64 && head.height == 32)
        #expect(head.graphJSON == nil && head.made == nil)
    }

    @Test func notAPNGHasNoHead() throws {
        let url = try scratch().appending(path: "note.png")
        try Data("not a picture".utf8).write(to: url)
        #expect(PictureHead.read(url) == nil)
    }

    @Test func itsGraphOpensAsANewFlow() throws {
        let library = try Fixture.library()
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: library)
        let graph = try editor.graphJSON()
        let url = try scratch().appending(path: "lighthouse_0001.flow.json")

        let opened = try FlowEditor.create(at: url, fromGraph: graph, library: library)
        #expect(opened.flow.nodes.count == editor.flow.nodes.filter { !$0.isBypassed }.count)
        #expect(opened.flow.links.count > 0)
        #expect(opened.problems.isEmpty)
        // Laid out by the core: no two nodes on top of each other.
        #expect(Set(opened.flow.nodes.map { "\($0.position.x),\($0.position.y)" }).count == opened.flow.nodes.count)
    }

    @Test func outputsAreNumberedOnFromTheHighest() throws {
        let folder = try scratch()
        #expect(OutputNaming.next(in: folder, prefix: "lighthouse").lastPathComponent == "lighthouse_0001.png")
        for name in ["lighthouse_0001.png", "lighthouse_0007.png", "other_0040.png", "lighthouse_draft.png"] {
            try Data().write(to: folder.appending(path: name))
        }
        #expect(OutputNaming.next(in: folder, prefix: "lighthouse").lastPathComponent == "lighthouse_0008.png")
        #expect(OutputNaming.next(in: folder, prefix: "").lastPathComponent == "image_0001.png")
    }

    @Test func theGalleryListsOutputsNewestFirstByFlow() async throws {
        let root = try scratch()
        let old = root.appending(path: "outputs/dusk/dusk_0001.png")
        let new = root.appending(path: "outputs/dawn/dawn_0001.png")
        for url in [old, new] { try PNGFixture.write(PNGFixture.head(width: 8, height: 8, flow: nil), to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        // Outside outputs/: not the gallery's.
        try PNGFixture.write(PNGFixture.head(width: 8, height: 8, flow: nil), to: root.appending(path: "inputs/photo.png"))

        let gallery = Gallery()
        await gallery.refresh(roots: [root, root])
        #expect(gallery.pictures.map(\.url.lastPathComponent) == ["dawn_0001.png", "dusk_0001.png"])
        #expect(gallery.flows == ["dawn", "dusk"])
        gallery.filter = "dusk"
        #expect(gallery.shown.map(\.flow) == ["dusk"])

        gallery.pick(gallery.pictures[0].url)
        gallery.pick(gallery.pictures[1].url, adding: true)
        #expect(gallery.picked.count == 2)
        // Removed here rather than sent to the Trash, which is the person's.
        #expect(gallery.trash(gallery.picked, mover: { try FileManager.default.removeItem(at: $0) }) == 0)
        #expect(gallery.pictures.isEmpty && gallery.chosen == nil)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
