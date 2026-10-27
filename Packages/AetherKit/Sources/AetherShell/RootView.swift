import AetherDesign
import DiffuseCore
import DiffuseUI
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
            Group {
                switch model.active {
                case .diffuse: DiffuseWorkspace(model: model.diffuse)
                default: PlannedWorkspace(workspace: model.active)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            SpineText(documentName, font: .system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkHi)
                .padding(.vertical, 8)
                .help(model.diffuse.editor?.url.path ?? "Aether")
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
                RailButton("Search", style: .field, help: model.active == .diffuse ? "Find a node  ⇥" : "Search") {
                    if model.active == .diffuse { model.diffuse.openLibrary() }
                }
                RailButton(model.active.navigatorLabel, isOn: model.active == .diffuse && model.diffuse.libraryOpen, help: "\(model.active.navigatorLabel)  ⌘0") {
                    model.toggleNavigator()
                }
                RailButton("Inspector", isOn: model.active == .diffuse && model.diffuse.inspectorOpen, help: "Inspector  ⌘\\") {
                    model.toggleInspector()
                }
            }
        }
        .padding(.bottom, 10)
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .background(Color.rail)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 1) }
    }

    private var documentName: String {
        model.active == .diffuse ? (model.diffuse.editor?.name ?? "Aether") : "Aether"
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
            Text("Designed, not built yet. It lands in \(workspace.milestone) of the plan; Diffuse is first.")
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
