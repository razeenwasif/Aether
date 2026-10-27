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

    public var isBuilt: Bool { self == .diffuse }
}

/// The window's state: which workspace is on screen, and each one's model.
@MainActor
@Observable
public final class AppModel {
    public var active: Workspace = .diffuse
    public let diffuse = DiffuseWorkspaceModel()

    public init() {}

    public func toggleNavigator() {
        guard active == .diffuse else { return }
        withAnimation { diffuse.libraryOpen.toggle() }
    }

    public func toggleInspector() {
        guard active == .diffuse else { return }
        withAnimation { diffuse.inspectorOpen.toggle() }
    }

    public func run() {
        if active == .diffuse { diffuse.run() }
    }
}
