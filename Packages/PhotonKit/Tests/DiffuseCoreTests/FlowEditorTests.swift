import Foundation
import Testing
@testable import DiffuseCore

/// Proton's own fixtures: the v1 catalogue and model lists, the lighthouse
/// flow, and a recorded SDXL run.
enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func library() throws -> NodeLibrary {
        try NodeLibrary(catalogueJSON: text("catalogue-v1.json"), modelsJSON: text("models.json"), source: .builtIn)
    }

    /// The lighthouse flow, copied somewhere a test may write it.
    static func lighthouse() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "photon-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: "lighthouse.flow.json")
        try FileManager.default.copyItem(at: url("lighthouse.flow.json"), to: copy)
        return copy
    }
}

@MainActor
struct FlowEditorTests {
    @Test func opensTheLighthouseFlowWithNothingWrong() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        #expect(editor.flow.nodes.count == 7)
        #expect(editor.flow.links.count == 9)
        #expect(editor.problems.isEmpty)
        #expect(editor.name == "lighthouse")
        #expect(!editor.isDirty)
    }

    @Test func eachBatchIsOneUndoStep() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let before = editor.flow.node("5")!.position
        editor.apply([.place(id: "5", at: CGPoint(x: 500, y: 40)), .place(id: "6", at: CGPoint(x: 700, y: 40))])
        #expect(editor.flow.node("5")!.position == CGPoint(x: 500, y: 40))
        #expect(editor.isDirty && editor.canUndo)
        editor.undo()
        #expect(editor.flow.node("5")!.position == before)
        #expect(editor.flow.node("6")!.position == CGPoint(x: 596, y: 16))
        #expect(!editor.isDirty && editor.canRedo)
    }

    @Test func eachStepIsToldByNameWithTheNodesItAdded() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        var told: [(String, [String])] = []
        editor.onStep = { told.append(($0, $1)) }
        editor.apply([.place(id: "5", at: CGPoint(x: 500, y: 40))])
        let added = try #require(editor.apply([.add(type: "PreviewImage", at: CGPoint(x: 800, y: 16))]))
        editor.apply([.place(id: "1", at: CGPoint(x: 99, y: 99)), .connect(from: "6:image", to: "1:checkpoint")])
        #expect(told.map(\.0) == ["Move", "Add a Node"] && told[1].1 == added, "a refused batch is no step")
        #expect(editor.undo() && editor.undo() && !editor.undo(), "undo answers whether there was a step")
        #expect(told.count == 2, "undoing isn't a new step")
    }

    @Test func thePictureTargetIsTheNodeUsePictureWouldChoose() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        #expect(editor.pictureTarget(nil, field: nil) == nil, "no Load Image: one would be added")
        let added = try #require(editor.apply([.add(type: "LoadImage", at: .zero)])?.first)
        let target = try #require(editor.pictureTarget(nil, field: nil))
        #expect(target.node == added && target.field == "image")
        #expect(editor.usePicture("inputs/a.png") == added)
    }

    @Test func aRefusedBatchChangesNothing() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let before = editor.flow
        // The move is fine; the link joins an IMAGE output to a field. Neither lands.
        let added = editor.apply([.place(id: "1", at: CGPoint(x: 99, y: 99)), .connect(from: "6:image", to: "1:checkpoint")])
        #expect(added == nil)
        #expect(editor.refusal != nil)
        #expect(editor.flow == before)
        #expect(!editor.canUndo)
    }

    @Test func addConnectAndRemoveANode() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        let added = try #require(editor.apply([.add(type: "PreviewImage", at: CGPoint(x: 800, y: 16))]))
        let preview = try #require(added.first)
        editor.apply([.connect(from: "6:image", to: "\(preview):images")])
        #expect(editor.flow.link(into: "\(preview):images")?.from == "6:image")
        editor.apply([.remove(ids: [preview])])
        #expect(editor.flow.node(preview) == nil)
        #expect(editor.flow.links.count == 9)
    }

    @Test func aFieldOutOfRangeIsRefused() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        // Width is 64...4096 in steps of 8.
        #expect(editor.apply([.set(id: "4", name: "width", value: .int(1001))]) == nil)
        #expect(editor.refusal?.contains("multiple of 8") == true)
        #expect(editor.apply([.set(id: "4", name: "width", value: .int(8192))]) == nil)
        #expect(editor.apply([.set(id: "4", name: "width", value: .double(1024.5))]) == nil)
        #expect(editor.apply([.set(id: "4", name: "width", value: .int(1152))]) != nil)
        #expect(editor.flow.node("4")?.values["width"] == .int(1152))
    }

    @Test func savesAndReopens() throws {
        let url = try Fixture.lighthouse()
        let library = try Fixture.library()
        let editor = try FlowEditor.open(url, library: library)
        editor.apply([.place(id: "7", at: CGPoint(x: 640, y: 300)), .note("Lighthouse study")])
        try editor.save()
        #expect(!editor.isDirty)
        let again = try FlowEditor.open(url, library: library)
        #expect(again.flow.node("7")?.position == CGPoint(x: 640, y: 300))
        #expect(again.flow.note == "Lighthouse study")
    }

    @Test func everyTemplateMakesAFlowThatCanRun() throws {
        let library = try Fixture.library()
        for template in ["textToImage", "hiresFix", "flux"] {
            let url = FileManager.default.temporaryDirectory.appending(path: "\(template).flow.json")
            let editor = try FlowEditor.create(at: url, template: template, library: library)
            #expect(!editor.flow.nodes.isEmpty, "\(template)")
            #expect(throws: Never.self, "\(template)") { _ = try editor.graphJSON() }
        }
    }

    @Test func seedsMoveAfterARunByTheirMode() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        #expect(editor.seedsAfterRun().isEmpty)
        editor.apply([.seed(id: "5", mode: .increment)])
        #expect(editor.seedsAfterRun() == [.set(id: "5", name: "seed", value: .int(43))])
    }

    @Test func aFlowWithNoOutputCannotRun() throws {
        let editor = try FlowEditor.open(Fixture.lighthouse(), library: Fixture.library())
        editor.apply([.remove(ids: ["7"])])
        #expect(editor.problems.contains { $0.message.contains("nothing to run") })
        #expect(throws: (any Error).self) { _ = try editor.graphJSON() }
    }
}

struct WireFormatTests {
    @Test func opsEncodeInTheCoresShape() throws {
        let data = try JSONEncoder().encode([FlowOp.place(id: "5", at: CGPoint(x: 408.4, y: 16))])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        #expect(object?["op"] as? String == "place")
        #expect(object?["id"] as? String == "5")
        #expect(object?["at"] as? [Double] == [408, 16])
    }

    @Test func decodesProtonsRecordedRun() throws {
        let events = try sse(Fixture.text("run-sdxl.events"))
        #expect(events.first == .queued(position: 1))
        #expect(events.contains(.started))
        #expect(events.contains { if case .progress(id: "5", step: _, steps: 30) = $0 { true } else { false } })
        #expect(events.contains { if case .image = $0 { true } else { false } })
        #expect(events.last?.ends == true)
    }

    /// The gateway's server-sent events, read as the core reads them.
    private func sse(_ text: String) throws -> [RunEvent] {
        var out: [RunEvent] = []
        var kind = "", data = ""
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty {
                if !kind.isEmpty {
                    var object = (try? JSONSerialization.jsonObject(with: Data((data.isEmpty ? "{}" : data).utf8)) as? [String: Any]) ?? [:]
                    object["event"] = kind
                    if let event = try? JSONDecoder().decode(RunEvent.self, from: JSONSerialization.data(withJSONObject: object)) {
                        out.append(event)
                    }
                }
                kind = ""; data = ""
            } else if line.hasPrefix("event: ") {
                kind = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                data += String(line.dropFirst(6))
            }
        }
        return out
    }
}
