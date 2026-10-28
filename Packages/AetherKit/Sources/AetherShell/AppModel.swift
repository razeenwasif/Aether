import CanvasUI
import DiffuseUI
import Observation
import SwiftUI

/// The six workspaces, in the rail's order.
public enum Workspace: String, CaseIterable, Identifiable, Sendable {
    case design, model, game, canvas, diffuse, video

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }

    /// What the navigator toggle is called here: what the navigator holds.
    public var navigatorLabel: String {
        switch self {
        case .design: "Layers"
        case .model: "Outliner"
        case .game: "Entities"
        case .canvas: "Canvases"
        case .diffuse: "Nodes"
        case .video: "Media"
        }
    }

    /// The milestone that builds it (RESEARCH_PLAN.md §8).
    public var milestone: String {
        switch self {
        case .canvas, .model: "M2"
        case .diffuse: "M3"
        case .game: "M4"
        case .design, .video: "M5"
        }
    }

    public var isBuilt: Bool { self == .diffuse || self == .canvas }
}

/// The window's state: which workspace is on screen, and each one's model.
@MainActor
@Observable
public final class AppModel {
    public var active: Workspace = .diffuse
    public let diffuse = DiffuseWorkspaceModel()
    public let canvas = CanvasWorkspaceModel()

    public init() {
        // Send to Canvas: the picture as a new canvas, on screen.
        diffuse.canvasReceiver = { [weak self] bytes, name, keep in
            guard let self else { return }
            active = .canvas
            canvas.receive(bytes, named: name, keep: keep)
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
