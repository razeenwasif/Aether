import AetherGraph
import Foundation
import Testing
@testable import AetherShell
import CanvasCore

@MainActor
struct ProjectTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "aether-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let defaults = UserDefaults(suiteName: "aether-tests-\(UUID().uuidString)")!

    @Test func aNewProjectHasItsFoldersAndIsNeverWrittenOver() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "Lumen.aether")
        let project = try ProjectGraph.create(url)
        #expect(project.name == "Lumen" && ProjectGraph.isProject(url))
        for part in ["Canvases", "Flows", "project.json"] {
            #expect(FileManager.default.fileExists(atPath: url.appending(path: part).path), "\(part)")
        }
        _ = try project.asset(madeBy: "Canvases/a.canvas", named: "A", in: .canvas)
        project.saveNow()
        #expect(try ProjectGraph.create(url).assets.map(\.name) == ["A"], "made again: opened as it is")

        let plain = base.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!ProjectGraph.isProject(plain) && !ProjectGraph.isProject(base.appending(path: "missing")))
        try FileManager.default.createDirectory(at: plain.appending(path: "Flows"), withIntermediateDirectories: true)
        #expect(ProjectGraph.isProject(plain), "a folder of flows can start one")
    }

    @Test func aLinkNotSavedLeavesWithTheProject() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let one = try ProjectGraph.create(base.appending(path: "One.aether"))
        let model = AppModel(project: one, defaults: defaults, connecting: false)
        model.askAboutUnsaved = { _, _ in .drop }
        model.canvas.newCanvas(named: "Scene", preset: .pixel, width: 8, height: 8)
        let art = try one.asset(madeBy: "Flows/key.flow.json", named: "Key art", in: .diffuse)
        let png = try CanvasDocument.create(width: 2, height: 2, preset: .pixel, at: base.appending(path: "p.canvas")).png()
        try one.publish(art.id, blob: try await one.pool.store(png), width: 2, height: 2)
        model.canvas.place(try #require(one.asset(art.id)))
        await model.canvas.following?.value
        #expect(one.links.count == 1 && model.canvas.document?.state.dirty == true)

        let two = base.appending(path: "Two.aether")
        _ = try ProjectGraph.create(two)
        model.openProject(at: two)
        #expect(model.project.folder?.path == two.path)
        #expect(one.links.isEmpty, "the canvas was let go unsaved, and its link with it")
        #expect(try ProjectGraph.open(try #require(one.folder)).links.isEmpty, "and One was saved so")
    }

    @Test func switchingPointsEveryWorkspaceAtTheNewProject() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let one = try ProjectGraph.create(base.appending(path: "One.aether"))
        let oneFolder = try #require(one.folder)
        let model = AppModel(project: one, defaults: defaults, connecting: false)
        var asked: [[String]] = []
        model.askAboutUnsaved = { unsaved, _ in
            asked.append(unsaved)
            return .stay
        }
        #expect(model.canvas.folder.path == one.canvasesFolder?.path && model.diffuse.flowsFolder.path == one.flowsFolder?.path)

        // What's open in One, saved: the flow is One's last.
        model.diffuse.save()
        let oneFlow = try #require(model.diffuse.editor?.url)
        model.canvas.newCanvas(named: "Sky", preset: .pixel, width: 8, height: 8)
        #expect(model.canvas.document != nil)

        let two = base.appending(path: "Two.aether")
        _ = try ProjectGraph.create(two)
        // Unsaved work asks first: staying keeps everything as it was.
        model.canvas.change(.fillRect(layer: try #require(model.canvas.currentLayer).id, x: 0, y: 0, width: 2, height: 2, color: RGBA(255, 0, 0)), label: "Fill")
        model.openProject(at: two)
        #expect(asked == [["Sky"]] && model.project.folder?.path == oneFolder.path)
        model.askAboutUnsaved = { unsaved, _ in
            asked.append(unsaved)
            return .save
        }
        model.openProject(at: two)
        #expect(model.project.folder?.path == two.path && model.project.name == "Two")
        #expect(model.canvas.document == nil && model.canvas.folder.path == two.appending(path: "Canvases").path && model.canvas.canvases.isEmpty)
        #expect(model.diffuse.flowsFolder.path == two.appending(path: "Flows").path)
        #expect(model.diffuse.editor?.url.deletingLastPathComponent().path == two.appending(path: "Flows").path, "a new flow, in Two")
        #expect(model.canvas.project === model.project && model.diffuse.project === model.project)
        #expect(defaults.string(forKey: "aether.project") == two.path && model.recentProjects.first?.path == two.path)

        // Two's new flow is unsaved, but untouched: nothing to ask about.
        #expect(model.diffuse.editor?.isDirty == true && !model.diffuse.hasUnsavedEdits)
        model.openProject(at: oneFolder)
        #expect(asked == [["Sky"], ["Sky"]], "asked twice about the canvas, never about an untouched flow")
        #expect(model.diffuse.editor?.url.path == oneFlow.path, "One's own last flow")
        #expect(model.canvas.canvases.map(\.name) == ["Sky"])
        #expect(model.otherRecentProjects.map(\.path) == [two.path])

        // Not a project: refused, and nothing changes.
        model.openProject(at: base.appending(path: "nothing"))
        #expect(model.project.folder?.path == oneFolder.path && model.diffuse.notice?.contains("isn’t a project") == true)

        // Opened again from scratch, the last project is the one open.
        #expect(AppModel.openLastProject(defaults).folder?.path == oneFolder.path)
    }
}
