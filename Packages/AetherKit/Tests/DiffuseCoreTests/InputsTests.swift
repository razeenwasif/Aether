import DiffuseBridge
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DiffuseCore

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aether-inputs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A picture of `width` × `height` pixels in one colour, as `type`.
private func picture(_ type: UTType, width: Int = 8, height: Int = 6, red: CGFloat = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

/// An image-to-image flow, from the core's starter, saved in a folder of its own.
@MainActor
private func imageToImage() throws -> FlowEditor {
    let editor = try FlowEditor.create(at: scratch().appending(path: "redraw.flow.json"), template: "imageToImage", library: Fixture.library())
    try editor.save()
    return editor
}

@MainActor
struct InputsTests {
    @Test func aPictureIsKeptAsAPNGInTheFlowsInputs() throws {
        let editor = try imageToImage()
        let source = try scratch().appending(path: "Holiday photo.jpg")
        try picture(.jpeg).write(to: source)

        let name = try FlowInputs.keep(source, flow: editor.url, key: nil)
        #expect(name == "inputs/Holiday-photo.png")
        let kept = try Data(contentsOf: FlowInputs.file(name, flow: editor.url))
        #expect(kept.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(try FlowInputs.keep(source, flow: editor.url, key: nil) == name, "the same picture is the same file")

        let notAPicture = try scratch().appending(path: "notes.png")
        try Data("plain text".utf8).write(to: notAPicture)
        #expect(throws: FlowInputs.Failure.self) { try FlowInputs.keep(notAPicture, flow: editor.url, key: nil) }
    }

    @Test func aPictureGoesToTheLoadImageOrAddsOne() throws {
        let editor = try imageToImage()
        let load = try #require(editor.flow.nodes.first { $0.type == "LoadImage" })
        #expect(editor.usePicture("inputs/a.png") == load.id)
        #expect(editor.flow.node(load.id)?.values["image"] == .string("inputs/a.png"))

        let plain = try FlowEditor.create(at: scratch().appending(path: "t.flow.json"), template: "textToImage", library: Fixture.library())
        let added = try #require(plain.usePicture("inputs/b.png", at: CGPoint(x: 40, y: 600)))
        let node = try #require(plain.flow.node(added))
        #expect(node.type == "LoadImage" && node.values["image"] == .string("inputs/b.png"))
        #expect(node.position == CGPoint(x: 40, y: 600) && plain.selection == [added])
    }

    @Test func aMissingPictureIsAProblemOnItsNode() throws {
        let editor = try imageToImage()
        let load = try #require(editor.flow.nodes.first { $0.type == "LoadImage" })
        editor.usePicture("inputs/gone.png")
        let problem = try #require(editor.problems(at: load.id).first { $0.input == "image" })
        #expect(problem.message.contains("inputs/gone.png"))

        let source = try scratch().appending(path: "here.png")
        try picture(.png).write(to: source)
        editor.usePicture(try FlowInputs.keep(source, flow: editor.url, key: nil))
        #expect(editor.problems(at: load.id).allSatisfy { $0.input != "image" })
    }

    @Test func aPictureInTheFlowsFolderIsNamedWhereItIs() throws {
        let flow = try scratch().appending(path: "f.flow.json")
        let root = FlowInputs.root(of: flow)
        #expect(FlowInputs.name(of: root.appending(path: "outputs/f/f_0001.png.sealed"), flow: flow) == "outputs/f/f_0001.png")
        #expect(FlowInputs.name(of: URL(fileURLWithPath: "/elsewhere/x.png"), flow: flow) == nil)
        #expect(FlowInputs.mask(node: "3", flow: flow).lastPathComponent == "f.3.mask.png")
    }

    @Test func aRunSendsEachPictureFirstAndNamesItsUpload() async throws {
        let editor = try imageToImage()
        let source = try scratch().appending(path: "photo.png")
        let bytes = try picture(.png)
        try bytes.write(to: source)
        let load = try #require(editor.usePicture(try FlowInputs.keep(source, flow: editor.url, key: nil)))

        let backend = RecordingBackend()
        let queue = RunQueue(backend: backend)
        queue.run(editor)
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(run.phase == .done(seconds: 0.1))

        let uploads = await backend.uploads
        #expect(uploads == [bytes], "sent as it is, with no mask painted")
        let sent = try #require(await backend.graphs.first)
        let graph = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let nodes = try #require(graph?["nodes"] as? [[String: Any]])
        let values = try #require(nodes.first { $0["id"] as? String == load }?["values"] as? [String: Any])
        #expect(values["image"] as? String == "upload1")
    }

    @Test func aPaintedMaskIsSentInThePicturesAlpha() async throws {
        let editor = try imageToImage()
        let source = try scratch().appending(path: "photo.png")
        let bytes = try picture(.png)
        try bytes.write(to: source)
        let load = try #require(editor.usePicture(try FlowInputs.keep(source, flow: editor.url, key: nil)))
        try picture(.png, red: 1).write(to: FlowInputs.mask(node: load, flow: editor.url))

        let backend = RecordingBackend()
        let queue = RunQueue(backend: backend)
        queue.run(editor)
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        let sent = try #require(await backend.uploads.first)
        #expect(sent != bytes)
        let source2 = try #require(CGImageSourceCreateWithData(sent as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source2, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    @Test func aRunWithAMissingPictureFailsBeforeSendingAnything() async throws {
        let editor = try imageToImage()
        editor.usePicture("inputs/gone.png")
        let backend = RecordingBackend()
        let queue = RunQueue(backend: backend)
        queue.run(editor)
        let run = try #require(queue.runs.first)
        for _ in 0..<200 where run.phase.isLive { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed(let why) = run.phase else { Issue.record("not failed: \(run.phase)"); return }
        #expect(why.contains("inputs/gone.png"))
        let graphs = await backend.graphs
        let uploads = await backend.uploads
        #expect(graphs.isEmpty && uploads.isEmpty)
    }
}

/// A backend that keeps what it was sent, and whose runs end at once.
private actor RecordingBackend: ImageBackend {
    private(set) var uploads: [Data] = []
    private(set) var graphs: [String] = []

    nonisolated var displayName: String { "Recording" }
    func health() async -> Health { .looking }
    func library() async throws -> NodeLibrary { try Fixture.library() }
    func upload(_ picture: Data) async throws -> String {
        uploads.append(picture)
        return "upload\(uploads.count)"
    }
    func run(graphJSON: String) async throws -> Queued {
        graphs.append(graphJSON)
        return Queued(run: "run1", position: 0)
    }
    nonisolated func events(run: String) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.done(seconds: 0.1))
            continuation.finish()
        }
    }
    func image(_ id: String) async throws -> Data { Data() }
    func cancel(run: String) async throws {}
}
