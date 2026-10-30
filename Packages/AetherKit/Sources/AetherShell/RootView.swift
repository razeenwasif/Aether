import AetherDesign
import AppKit
import AetherGraph
import CanvasUI
import DiffuseCore
import DiffuseUI
import GameUI
import ModelUI
import SwiftUI

/// The window: the 32 pt rail, then the active workspace edge to edge.
public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            WorkspaceRail(model: model)
            ZStack(alignment: .top) {
                Group {
                    switch model.active {
                    case .diffuse: DiffuseWorkspace(model: model.diffuse)
                    case .canvas: CanvasWorkspace(model: model.canvas)
                    case .model: ModelWorkspace(model: model.modeling)
                    case .game: GameWorkspace(model: model.game)
                    default: PlannedWorkspace(workspace: model.active)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.omnibar.isOpen {
                    // A click anywhere else closes it.
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture { model.omnibar.close() }
                        .transition(.opacity)
                    Omnibar(model: model, omnibar: model.omnibar)
                        .padding(.top, 72)
                        .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.omnibar.isOpen)
        }
        .background(Color.obsidian0)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowChrome())
    }
}

/// The rail: traffic lights, the open document, the six workspaces, Run,
/// Search and the two panel toggles, every label set vertically.
struct WorkspaceRail: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // The window's traffic lights are stacked into this space.
            Color.clear.frame(height: WindowChrome.lightsHeight)
            // The project, as the design has it: its menu opens another.
            Button { ProjectMenu.show(for: model) } label: {
                SpineText(model.project.name, font: .system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.inkHi)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(model.project.name) · \(model.project.folder?.path ?? "not saved") · New Project, Open Project")
            .accessibilityLabel("Project \(model.project.name)")
            .accessibilityHint("Opens the project menu")
            divider
            VStack(spacing: 2) {
                ForEach(Workspace.allCases) { workspace in
                    RailButton(workspace.title, isOn: model.active == workspace, help: "\(workspace.title)  ⌘\(workspace.shortcut.character)") {
                        model.active = workspace
                    }
                }
            }
            Spacer(minLength: 12)
            runButton
            divider
            VStack(spacing: 2) {
                RailButton("Search", style: .field, isOn: model.omnibar.isOpen, help: "Tools, actions, assets, go to  ⌘K") {
                    model.toggleOmnibar()
                }
                RailButton(model.active.navigatorLabel, isOn: model.navigatorOpen, help: "\(model.active.navigatorLabel)  ⌘0") {
                    model.toggleNavigator()
                }
                RailButton("Inspector", isOn: model.inspectorOpen, help: "Inspector  ⌘\\") {
                    model.toggleInspector()
                }
            }
        }
        .padding(.bottom, 10)
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                Color.rail
                WindowDragArea()
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Color.line2).frame(width: 16, height: 1).padding(.vertical, 10)
    }

    /// One place, one shortcut, a verb per workspace.
    @ViewBuilder private var runButton: some View {
        if model.active == .diffuse {
            if let run = model.diffuse.queue.active {
                RailButton("Generating", style: .running(progress: progress(of: run)), help: "Generating · ⌘. cancels") {
                    model.diffuse.queue.cancel(run)
                }
            } else {
                RailButton("Generate", style: .run, help: "Generate  ⌘↩") { model.run() }
            }
        } else if model.active == .canvas {
            RailButton("Export", style: .run, help: "Export: a PNG, a sprite sheet or Photoshop  ⌘E") { model.run() }
                .opacity(model.canvas.document == nil ? 0.35 : 1)
                .disabled(model.canvas.document == nil)
        } else if model.active == .game {
            RailButton(model.game.playing ? "Stop" : "Play", style: .run, help: model.game.playing ? "Stop: Esc" : "Play: the room from the game's start, as it is now  ⌘↩") { model.run() }
                .opacity(model.game.document == nil ? 0.35 : 1)
                .disabled(model.game.document == nil)
        } else if model.active == .model {
            RailButton("Render", style: .run, help: "Render: the scene from the camera, and its depth, published as assets  ⌘↩") { model.run() }
                .opacity(model.modeling.document == nil ? 0.35 : 1)
                .disabled(model.modeling.document == nil)
        } else {
            RailButton(verb(model.active), style: .run, help: "\(model.active.title) is not built yet") {}
                .opacity(0.35)
                .disabled(true)
        }
    }

    private func progress(of run: RunItem) -> Double {
        guard let node = run.runningNode, let steps = run.steps[node] else { return 0.1 }
        return steps.fraction
    }

    private func verb(_ workspace: Workspace) -> String {
        switch workspace {
        case .design: "Preview"
        case .model: "Render"
        case .game, .video: "Play"
        case .canvas: "Export"
        case .diffuse: "Generate"
        }
    }
}

/// A workspace designed but not built yet.
struct PlannedWorkspace: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 14) {
            Text(workspace.title).font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.inkHi)
            Text("Designed, not built yet. It lands in \(workspace.milestone) of the plan; Diffuse, Canvas, Model and Game are built.")
                .font(.system(size: 13))
                .foregroundStyle(Color.ink)
            Link("Open the design canvas", destination: URL(string: "https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv")!)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.obsidian0)
    }
}

/// The project menu, under the rail's project name: new, open, recent, and
/// the folder in the Finder.
@MainActor
enum ProjectMenu {
    static func show(for model: AppModel) {
        let menu = NSMenu()
        menu.addItem(ActionItem("New Project…") { model.newProject() })
        menu.addItem(ActionItem("Open Project…") { model.chooseProject() })
        let recent = model.otherRecentProjects
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent"))
            for url in recent {
                menu.addItem(ActionItem(url.deletingPathExtension().lastPathComponent) { model.openProject(at: url) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { model.showProjectInFinder() })
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        let point: NSPoint
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.window === view.window {
            point = view.convert(event.locationInWindow, from: nil)
        } else {
            // Pressed from the keyboard or with VoiceOver: under the name.
            point = NSPoint(x: 34, y: view.isFlipped ? 64 : view.bounds.height - 64)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// A menu item that runs a closure.
    private final class ActionItem: NSMenuItem {
        private let run: () -> Void

        init(_ title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("not from a nib") }

        @objc private func fire() { run() }
    }
}
