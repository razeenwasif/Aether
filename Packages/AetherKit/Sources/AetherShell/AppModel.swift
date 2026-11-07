import AetherGraph
import AppKit
import CanvasUI
import DesignUI
import DiffuseUI
import GameUI
import ModelUI
import Observation
import SwiftUI

extension Workspace {
    public var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// The window's state: the project, which workspace is on screen, and each
/// one's model.
@MainActor
@Observable
public final class AppModel {
    public var active: Workspace = .diffuse
    /// The project every workspace views: its assets, links and history.
    public internal(set) var project: ProjectGraph
    public let diffuse: DiffuseWorkspaceModel
    public let canvas: CanvasWorkspaceModel
    public let modeling: ModelWorkspaceModel
    public let game: GameWorkspaceModel
    public let design: DesignWorkspaceModel
    /// The omnibar (⌘K): tools, actions, assets and Go to in one list.
    public let omnibar = OmnibarModel()
    /// The flows in the flows folder, for Go to: read off the main actor,
    /// so opening the omnibar never waits on the disk (§7a).
    public private(set) var flowFiles: [URL] = []
    /// Projects opened lately, newest first.
    public internal(set) var recentProjects: [URL] = []
    /// Where settings kept between launches go; tests use their own.
    @ObservationIgnored let defaults: UserDefaults
    /// How to ask about changes not saved before another project opens or
    /// the app quits: what isn't saved, and what's about to happen (`opening
    /// Two`, `quitting`). An alert; tests answer.
    @ObservationIgnored var askAboutUnsaved: @MainActor ([String], String) -> LeaveAnswer = AppModel.alertAboutUnsaved
    /// Open the window again: staying after closing it to quit.
    @ObservationIgnored public var reopenWindow: (() -> Void)?
    @ObservationIgnored private var quitting: (any NSObjectProtocol)?

    /// The project last open (or `~/Documents/Aether`), its workspaces
    /// pointed at its `Canvases/`, `Flows/` and `Models/`. `connecting` false leaves
    /// Diffuse's gateway alone, for tests.
    public init(project: ProjectGraph? = nil, defaults: UserDefaults = .standard, connecting: Bool = true) {
        self.defaults = defaults
        let project = project ?? Self.openLastProject(defaults)
        self.project = project
        let folder = project.folder ?? Self.defaultProjectFolder
        diffuse = DiffuseWorkspaceModel(flowsFolder: folder.appending(path: "Flows", directoryHint: .isDirectory), defaults: defaults, connecting: connecting)
        canvas = CanvasWorkspaceModel(folder: folder.appending(path: "Canvases", directoryHint: .isDirectory), defaults: defaults)
        modeling = ModelWorkspaceModel(folder: folder.appending(path: "Models", directoryHint: .isDirectory))
        game = GameWorkspaceModel(folder: folder.appending(path: "Games", directoryHint: .isDirectory))
        design = DesignWorkspaceModel(folder: folder.appending(path: "Designs", directoryHint: .isDirectory))
        recentProjects = (defaults.stringArray(forKey: "aether.recentProjects") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        diffuse.project = project
        canvas.project = project
        modeling.project = project
        design.project = project
        // Send to Canvas: the picture as a new canvas, on screen, its layer
        // following the flow's newest picture.
        diffuse.canvasReceiver = { [weak self] bytes, name, keep, asset in
            guard let self else { return }
            active = .canvas
            canvas.receive(bytes, named: name, keep: keep, linking: asset)
        }
        diffuse.canvasAsset = { [weak self] url in
            guard let self else { throw CocoaError(.userCancelled) }
            return try await canvas.asset(ofCanvasAt: url)
        }
        // Send to Game: art brought into the game open, on screen.
        let toGame: ([URL]) -> Void = { [weak self] urls in
            guard let self else { return }
            active = .game
            game.importFiles(urls)
        }
        diffuse.gameReceiver = toGame
        canvas.gameReceiver = toGame
        diffuse.showSource = { [weak self] in self?.showSource($0) }
        canvas.showSource = { [weak self] in self?.showSource($0) }
        design.showSource = { [weak self] in self?.showSource($0) }
        Task { await refreshFlowFiles() }
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.modeling.saveNow()
                self?.project.saveNow()
            }
        }
    }

    /// `~/Documents/Aether`, which already held `Canvases/` and `Flows/`
    /// before there were projects.
    public nonisolated static var defaultProjectFolder: URL {
        URL.documentsDirectory.appending(path: "Aether", directoryHint: .isDirectory)
    }

    /// The project last open, or the default one. One that can't be read is
    /// kept in memory, not written over.
    static func openLastProject(_ defaults: UserDefaults) -> ProjectGraph {
        let last = defaults.string(forKey: "aether.project").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let folder = last.flatMap { ProjectGraph.isProject($0) ? $0 : nil } ?? defaultProjectFolder
        do {
            return try ProjectGraph.open(folder)
        } catch {
            let project = ProjectGraph(folder: nil)
            project.problem = "\(folder.path)/project.json couldn’t be read, so links this session aren’t saved: \(error.localizedDescription)"
            return project
        }
    }

    /// Read the flows folder again, off the main actor.
    func refreshFlowFiles() async {
        let folder = diffuse.flowsFolder
        flowFiles = await Task.detached {
            let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return found.filter { $0.lastPathComponent.hasSuffix(".flow.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
    }

    /// Open what makes an asset, in the workspace that makes it.
    public func showSource(_ asset: Asset) {
        let url = project.url(of: asset.document)
        switch asset.source {
        case .diffuse:
            active = .diffuse
            diffuse.openFlow(at: url)
        case .canvas:
            active = .canvas
            canvas.open(url)
        case .model:
            active = .model
            modeling.open(project.url(of: ModelWorkspaceModel.scenePath(ofRender: asset.document)))
        default:
            break
        }
    }

    /// Undo in the workspace on screen: its document's newest step, its own
    /// or a project step made in it.
    public func undo() {
        switch active {
        case .canvas: canvas.undo()
        case .model: modeling.undo()
        case .game: game.undo()
        case .design: design.undo()
        case .diffuse: diffuse.undo()
        default: break
        }
    }

    public func redo() {
        switch active {
        case .canvas: canvas.redo()
        case .model: modeling.redo()
        case .game: game.redo()
        case .design: design.redo()
        case .diffuse: diffuse.redo()
        default: break
        }
    }

    public var undoLabel: String? {
        switch active {
        case .canvas: canvas.undoLabel
        case .model: modeling.undoLabel
        case .game: game.undoLabel
        case .design: design.undoLabel
        case .diffuse: diffuse.undoLabel
        default: nil
        }
    }

    public var redoLabel: String? {
        switch active {
        case .canvas: canvas.redoLabel
        case .model: modeling.redoLabel
        case .game: game.redoLabel
        case .design: design.redoLabel
        case .diffuse: diffuse.redoLabel
        default: nil
        }
    }

    public func toggleNavigator() {
        withAnimation {
            switch active {
            case .diffuse: diffuse.libraryOpen.toggle()
            case .canvas: canvas.navigatorOpen.toggle()
            case .model: modeling.navigatorOpen.toggle()
            case .game: game.navigatorOpen.toggle()
            case .design: design.navigatorOpen.toggle()
            default: break
            }
        }
    }

    public func toggleInspector() {
        withAnimation {
            switch active {
            case .diffuse: diffuse.inspectorOpen.toggle()
            case .canvas: canvas.inspectorOpen.toggle()
            case .model: modeling.inspectorOpen.toggle()
            case .game: game.inspectorOpen.toggle()
            case .design: design.inspectorOpen.toggle()
            default: break
            }
        }
    }

    /// Whether the navigator is out, in the workspace on screen.
    public var navigatorOpen: Bool {
        switch active {
        case .diffuse: diffuse.libraryOpen
        case .canvas: canvas.navigatorOpen && canvas.document != nil
        case .model: modeling.navigatorOpen && modeling.document != nil
        case .game: game.navigatorOpen && game.document != nil
        case .design: design.navigatorOpen && design.document != nil
        default: false
        }
    }

    public var inspectorOpen: Bool {
        switch active {
        case .diffuse: diffuse.inspectorOpen
        case .canvas: canvas.inspectorOpen && canvas.document != nil
        case .model: modeling.inspectorOpen && modeling.document != nil
        case .game: game.inspectorOpen && game.document != nil
        case .design: design.inspectorOpen && design.document != nil
        default: false
        }
    }

    /// The rail's verb: Generate in Diffuse, Export in Canvas, Preview in
    /// Design.
    public func run() {
        switch active {
        case .diffuse: diffuse.run()
        case .canvas: canvas.exportPNG()
        case .model: modeling.render()
        case .game: game.togglePlay()
        case .design: design.preview()
        default: break
        }
    }
}
