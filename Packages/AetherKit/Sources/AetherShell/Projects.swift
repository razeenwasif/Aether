import AetherGraph
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// `Name.aether`: a project, a package of `project.json`, `blobs/`,
    /// `Canvases/` and `Flows/` (declared in the app's Info.plist).
    public static let aetherProject = UTType(exportedAs: "dev.razeen.aether.project", conformingTo: .package)
}

/// Projects: opening one, making one, and the recent ones (RESEARCH_PLAN.md
/// §4, package format).
extension AppModel {
    /// Open the project in `folder`, after asking about changes not saved in
    /// any workspace. A folder that isn't one is refused.
    public func openProject(at folder: URL) {
        let folder = folder.standardizedFileURL
        guard folder.path != project.folder?.standardizedFileURL.path else { return }
        guard ProjectGraph.isProject(folder) else {
            return say("\(folder.lastPathComponent) isn’t a project: a project is a .aether package, or a folder with Canvases, Flows or Models in it.")
        }
        guard askToLeave(for: folder.deletingPathExtension().lastPathComponent) else { return }
        do {
            switchProject(to: try ProjectGraph.open(folder))
        } catch {
            say("Couldn’t open \(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// A new `Name.aether` project where the person says, opened.
    public func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "A project keeps its canvases, flows and the links between them together."
        panel.nameFieldStringValue = "Untitled"
        panel.allowedContentTypes = [.aetherProject]
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "aether" { url.appendPathExtension("aether") }
        guard askToLeave(for: url.deletingPathExtension().lastPathComponent) else { return }
        do {
            switchProject(to: try ProjectGraph.create(url))
        } catch {
            say("Couldn’t make \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Choose a project to open: a `.aether` package, or a folder.
    public func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open a Project"
        panel.message = "Choose a .aether project, or a folder of Canvases and Flows."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.aetherProject, .folder]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = project.folder?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    public func showProjectInFinder() {
        guard let folder = project.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Every workspace pointed at `next`. The documents open are let go
    /// first, while they still belong to the old project, so the links made
    /// with changes not saved go with them; then the old project is saved,
    /// and each workspace takes the new one.
    func switchProject(to next: ProjectGraph) {
        let folder = next.folder ?? Self.defaultProjectFolder
        canvas.switchFolder(to: next.canvasesFolder ?? folder.appending(path: "Canvases", directoryHint: .isDirectory))
        modeling.switchFolder(to: next.modelsFolder ?? folder.appending(path: "Models", directoryHint: .isDirectory))
        game.switchFolder(to: next.gamesFolder ?? folder.appending(path: "Games", directoryHint: .isDirectory))
        design.switchFolder(to: next.designsFolder ?? folder.appending(path: "Designs", directoryHint: .isDirectory))
        diffuse.switchFolder(to: next.flowsFolder ?? folder.appending(path: "Flows", directoryHint: .isDirectory))
        project.saveNow()
        project = next
        canvas.project = next
        modeling.project = next
        design.project = next
        diffuse.project = next
        omnibar.close()
        remember(folder)
        Task { await refreshFlowFiles() }
    }

    /// The project open now, kept for next launch and first among the
    /// recent ones.
    private func remember(_ folder: URL) {
        defaults.set(folder.path, forKey: "aether.project")
        recentProjects = Array(([folder] + recentProjects.filter { $0.standardizedFileURL.path != folder.standardizedFileURL.path }).prefix(8))
        defaults.set(recentProjects.map(\.path), forKey: "aether.recentProjects")
    }

    /// The recent projects still there, the one open now left out.
    public var otherRecentProjects: [URL] {
        recentProjects.filter { $0.standardizedFileURL.path != project.folder?.standardizedFileURL.path && ProjectGraph.isProject($0) }
    }

    /// Changes not saved in the canvas and the flow open: saved, dropped, or
    /// the switch called off. Answers whether to go on.
    func askToLeave(for name: String) -> Bool {
        askAboutUnsaved(before: "opening \(name)") != .stay
    }

    /// Whether to quit. A run still going is asked about first: quitting
    /// stops it. Then what isn't saved, as switching projects asks. A save
    /// that fails stays, having said why. Dropped, the links made with what's
    /// dropped go too, as they do when a project is left, or the project
    /// would be saved with links to layers that never were.
    public func shouldQuit() -> Bool {
        let running = diffuse.queue.live
        if !running.isEmpty {
            var flows: [String] = []
            for run in running where !flows.contains(run.flowName) { flows.append(run.flowName) }
            guard askAboutRuns(flows) else { return false }
        }
        let answer = askAboutUnsaved(before: "quitting")
        guard answer != .stay else { return false }
        guard answer == .drop else { return true }
        for path in [canvas.document?.state.dirty == true ? canvas.documentPath : nil, diffuse.hasUnsavedEdits ? diffuse.flowPath : nil, design.document?.unsaved.isEmpty == false ? design.documentPath : nil].compactMap({ $0 }) {
            project.discard(document: path)
        }
        return true
    }

    /// Ask, when anything isn't saved, and do what's answered: `.save` when
    /// it was all saved or there was nothing to save, `.drop` to leave it,
    /// `.stay` when asked to, or when a save failed, having said why.
    private func askAboutUnsaved(before doing: String) -> LeaveAnswer {
        var unsaved: [String] = []
        if let document = canvas.document, document.state.dirty { unsaved.append(document.name) }
        if let editor = diffuse.editor, diffuse.hasUnsavedEdits { unsaved.append(editor.name) }
        if let document = game.document, !document.unsaved.isEmpty { unsaved.append(document.name) }
        if let document = design.document, !document.unsaved.isEmpty { unsaved.append(document.name) }
        guard !unsaved.isEmpty else { return .save }
        let answer = askAboutUnsaved(unsaved, doing)
        guard answer == .save else { return answer }
        if canvas.document?.state.dirty == true { canvas.save() }
        if diffuse.hasUnsavedEdits { diffuse.save() }
        if game.document?.unsaved.isEmpty == false { game.saveNow() }
        if design.document?.unsaved.isEmpty == false { design.saveNow() }
        // A save that failed has said why; stay.
        let saved = canvas.document?.state.dirty != true && !diffuse.hasUnsavedEdits && game.document?.unsaved.isEmpty != false && design.document?.unsaved.isEmpty != false
        return saved ? .save : .stay
    }

    /// Stop the runs still going, as quitting does, waiting at most
    /// `seconds` for their backends to hear it: forge may be away, and
    /// quitting shouldn't hang on it.
    public func stopRuns(waiting seconds: Double = 3) async {
        guard !diffuse.queue.live.isEmpty else { return }
        let stopped = Flag()
        let queue = diffuse.queue
        Task {
            await queue.cancelAll()
            stopped.up = true
        }
        let end = ContinuousClock.now + .seconds(seconds)
        while !stopped.up, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func alertAboutRuns(_ flows: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit while \(ListFormatter.localizedString(byJoining: flows)) \(flows.count == 1 ? "is" : "are") running?"
        alert.informativeText = "Quitting stops \(flows.count == 1 ? "it" : "them"). What hasn’t been made yet is lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func alertAboutUnsaved(_ unsaved: [String], _ doing: String) -> LeaveAnswer {
        let alert = NSAlert()
        alert.messageText = "Save the changes to \(ListFormatter.localizedString(byJoining: unsaved)) before \(doing)?"
        alert.informativeText = "If you don’t save them, they’re lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .stay
        default: .drop
        }
    }

    /// A note to the person, in the workspace on screen.
    func say(_ text: String) {
        switch active {
        case .canvas: canvas.notice = text
        case .model: modeling.notice = text
        default: diffuse.notice = text
        }
    }
}

/// Set once something done elsewhere is done.
@MainActor
private final class Flag {
    var up = false
}

/// What to do with changes not saved before another project opens or the
/// app quits.
enum LeaveAnswer: Sendable {
    case save, stay, drop
}

/// Opens a `.aether` project double-clicked in the Finder, or dropped on the
/// Dock icon, once the window's model is there.
@MainActor
public final class AetherAppDelegate: NSObject, NSApplicationDelegate {
    public var model: AppModel? {
        didSet { openWaiting() }
    }
    private var waiting: [URL] = []

    public func application(_ application: NSApplication, open urls: [URL]) {
        waiting += urls
        openWaiting()
    }

    /// Quitting, by the menu, the Dock, a restart or closing the window, asks
    /// about runs still going and what isn't saved, and stops the runs. A
    /// field with the keys commits what's typed in it when it lets them go,
    /// so they're let go first and the question comes a moment later.
    /// Closing the window has already closed it by now, so staying brings it
    /// back.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        sender.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard model.shouldQuit() else {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { model.reopenWindow?() }
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
                Task {
                    await model.stopRuns()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    private func openWaiting() {
        guard let model, let url = waiting.last else { return }
        waiting = []
        model.openProject(at: url)
    }
}
