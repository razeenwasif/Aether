import AetherGraph
import AppKit
import CanvasUI
import DiffuseUI
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
    public let project: ProjectGraph
    public let diffuse = DiffuseWorkspaceModel()
    public let canvas = CanvasWorkspaceModel()
    /// The omnibar (⌘K): tools, actions, assets and Go to in one list.
    public let omnibar = OmnibarModel()
    /// The flows in the flows folder, for Go to: read off the main actor,
    /// so opening the omnibar never waits on the disk (§7a).
    public private(set) var flowFiles: [URL] = []
    @ObservationIgnored private var quitting: (any NSObjectProtocol)?

    public init(project: ProjectGraph? = nil) {
        let project = project ?? Self.openProject()
        self.project = project
        diffuse.project = project
        canvas.project = project
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
        diffuse.showSource = { [weak self] in self?.showSource($0) }
        canvas.showSource = { [weak self] in self?.showSource($0) }
        Task { await refreshFlowFiles() }
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [project] _ in
            MainActor.assumeIsolated { project.saveNow() }
        }
    }

    /// `~/Documents/Aether`, which already holds `Canvases/` and `Flows/`.
    /// One that can't be read is kept in memory, not written over.
    static func openProject() -> ProjectGraph {
        let folder = URL.documentsDirectory.appending(path: "Aether", directoryHint: .isDirectory)
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
        default:
            break
        }
    }

    /// Undo in the workspace on screen: its document's newest step, its own
    /// or a project step made in it.
    public func undo() {
        switch active {
        case .canvas: canvas.undo()
        case .diffuse: diffuse.undo()
        default: break
        }
    }

    public func redo() {
        switch active {
        case .canvas: canvas.redo()
        case .diffuse: diffuse.redo()
        default: break
        }
    }

    public var undoLabel: String? {
        switch active {
        case .canvas: canvas.undoLabel
        case .diffuse: diffuse.undoLabel
        default: nil
        }
    }

    public var redoLabel: String? {
        switch active {
        case .canvas: canvas.redoLabel
        case .diffuse: diffuse.redoLabel
        default: nil
        }
    }

    public func toggleNavigator() {
        withAnimation {
            switch active {
            case .diffuse: diffuse.libraryOpen.toggle()
            case .canvas: canvas.navigatorOpen.toggle()
            default: break
            }
        }
    }

    public func toggleInspector() {
        withAnimation {
            switch active {
            case .diffuse: diffuse.inspectorOpen.toggle()
            case .canvas: canvas.inspectorOpen.toggle()
            default: break
            }
        }
    }

    /// Whether the navigator is out, in the workspace on screen.
    public var navigatorOpen: Bool {
        switch active {
        case .diffuse: diffuse.libraryOpen
        case .canvas: canvas.navigatorOpen && canvas.document != nil
        default: false
        }
    }

    public var inspectorOpen: Bool {
        switch active {
        case .diffuse: diffuse.inspectorOpen
        case .canvas: canvas.inspectorOpen && canvas.document != nil
        default: false
        }
    }

    /// The rail's verb: Generate in Diffuse, Export in Canvas.
    public func run() {
        switch active {
        case .diffuse: diffuse.run()
        case .canvas: canvas.exportPNG()
        default: break
        }
    }
}
