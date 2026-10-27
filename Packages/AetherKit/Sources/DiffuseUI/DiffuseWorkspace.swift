import AppKit
import AetherDesign
import DiffuseCore
import SwiftUI

/// The Diffuse workspace: the flow edge to edge, with the node library and
/// the inspector floating over its sides, a status bar, the run's progress
/// and a tool dock that re-centres in the free space.
public struct DiffuseWorkspace: View {
    @Bindable var model: DiffuseWorkspaceModel

    public init(model: DiffuseWorkspaceModel) {
        self.model = model
    }

    private var onGraph: Bool { model.stage == .graph }
    private var leftInset: CGFloat { model.libraryOpen && onGraph ? 264 : 0 }
    private var rightInset: CGFloat { model.inspectorOpen ? 300 : 0 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if !onGraph {
                GalleryStage(model: model, leftInset: leftInset, rightInset: rightInset)
            } else if let editor = model.editor {
                FlowCanvas(model: model, editor: editor)
                    .id(editor.url)
            } else if let locked = model.lockedFlow {
                LockedFlow(model: model, url: locked)
            } else {
                Color.obsidian0
            }

            HStack(alignment: .top, spacing: 0) {
                if model.libraryOpen, onGraph, let editor = model.editor {
                    NodeLibraryPanel(model: model, library: editor.library)
                        .frame(width: 248)
                        .padding(8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if model.inspectorOpen {
                    Group {
                        if !onGraph {
                            GalleryInspector(model: model)
                        } else if let editor = model.editor {
                            DiffuseInspector(model: model, editor: editor)
                        }
                    }
                    .frame(width: 284)
                    .padding(8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            Group {
                if let editor = model.editor {
                    StatusBar(model: model, editor: editor)
                } else {
                    // No flow open, as while a sealed one waits: the switch stays.
                    StageSwitch(model: model)
                        .padding(.horizontal, 4)
                        .frame(height: 30)
                        .aeGlass(.floating, radius: 9)
                }
            }
            .padding(.leading, leftInset + 12)
            .padding(.top, 12)

            VStack {
                if let run = model.queue.runs.first {
                    RunHUD(model: model, run: run).padding(.top, 12)
                }
                Spacer()
                if let notice = model.notice {
                    NoticeView(text: notice) { model.notice = nil }
                        .padding(.bottom, 10)
                }
                if onGraph && model.editor != nil { ToolDock(model: model).padding(.bottom, 16) }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, leftInset)
            .padding(.trailing, rightInset)
        }
        .animation(Motion.panel, value: model.libraryOpen)
        .animation(Motion.panel, value: model.inspectorOpen)
        .animation(Motion.panel, value: model.stage)
        .background(Color.obsidian0)
        .modifier(StageKeys(model: model))
    }
}

/// Hands the window's key presses to the model while Diffuse is on screen.
private struct StageKeys: ViewModifier {
    let model: DiffuseWorkspaceModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { model.handleKey(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// A sealed flow that isn't shown until the person unlocks it.
private struct LockedFlow: View {
    @Bindable var model: DiffuseWorkspaceModel
    let url: URL

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 22)).foregroundStyle(Color.ink2)
            Text("\(url.lastPathComponent) is sealed.").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.inkHi)
            Text("Proton keeps it encrypted. Unlock with Touch ID or your password to open it; it stays sealed when you save.")
                .font(.system(size: 12)).foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                Button(model.sealUnlocking ? "Waiting for you…" : "Unlock", action: model.unlockLockedFlow)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.runFill)
                    .foregroundStyle(Color.obsidian0)
                    .disabled(model.sealUnlocking)
                Button("New Flow") { model.newFlow(template: "textToImage") }
                Button("Open Another…", action: model.chooseAndOpen)
            }
            .padding(.top, 4)
            if let said = model.sealSaid {
                Text(said).font(.system(size: 11.5)).foregroundStyle(Color.coral).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .padding(28)
        .aeGlass(.floating, radius: Radius.floating)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.obsidian0)
    }
}

/// The flow's name, whether it is saved, and how the server is.
private struct StatusBar: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor

    var body: some View {
        HStack(spacing: 10) {
            StageSwitch(model: model)
            Divider().frame(height: 12)
            HStack(spacing: 6) {
                if editor.isSealed {
                    Image(systemName: "lock.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.ink2)
                        .help("Sealed with Proton’s key: saved encrypted, and so are its outputs")
                        .accessibilityLabel("Sealed")
                }
                Text(editor.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi)
                if editor.isDirty {
                    Circle().fill(Color.ink).frame(width: 6, height: 6).help("Not saved: ⌘S")
                }
            }
            Divider().frame(height: 12)
            HStack(spacing: 5) {
                Circle().fill(HealthStyle.color(model.queue.health.state)).frame(width: 6, height: 6)
                Text(HealthStyle.label(model.queue.health)).font(.system(size: 11.5)).foregroundStyle(Color.ink)
            }
            .help(model.queue.health.message)
            if !editor.problems.isEmpty && model.stage == .graph {
                Divider().frame(height: 12)
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.amber)
                    Text(editor.problems.count == 1 ? "1 problem" : "\(editor.problems.count) problems")
                        .font(.system(size: 11.5)).foregroundStyle(Color.ink)
                }
                .help(editor.problems.map(\.message).joined(separator: "\n"))
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: 30)
        .aeGlass(.floating, radius: 9)
    }
}

/// The newest run: where it is, how far, and a way to stop it.
private struct RunHUD: View {
    @Bindable var model: DiffuseWorkspaceModel
    let run: RunItem

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(RunStyle.color(run.phase)).frame(width: 7, height: 7)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi).lineLimit(1)
            if let steps = activeSteps {
                Text("\(steps.step)/\(steps.steps)").font(.aeMono).foregroundStyle(Color.ink)
                ProgressView(value: steps.fraction).progressViewStyle(.linear).frame(width: 120).tint(.ice)
            }
            if run.phase.isLive {
                Button("Cancel") { model.queue.cancel(run) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkHi)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .aeGlass(.floating, radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(run.phase.isLive ? Color.ice.opacity(0.3) : .clear))
    }

    private var title: String {
        if case .running = run.phase, let node = run.runningNode {
            let type = model.editor?.flow.node(node).flatMap { model.editor?.library.catalogue.node($0.type)?.title }
            return "Running \(type ?? "node \(node)")"
        }
        return RunStyle.label(run.phase)
    }

    private var activeSteps: RunItem.Steps? {
        guard run.phase.isLive else { return nil }
        if let node = run.runningNode, let steps = run.steps[node] { return steps }
        return nil
    }
}

private struct NoticeView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.amber)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.inkHi).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink2)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .aeGlass(.floating, radius: 10)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }
}

/// Tools for the flow, centred in whatever space the panels leave.
private struct ToolDock: View {
    @Bindable var model: DiffuseWorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton("plus.square", label: "Add a node (⇥)", action: model.openLibrary)
            IconButton("square.on.square", label: "Duplicate (⌘D)", action: model.duplicateSelection)
            IconButton("eye.slash", label: "Bypass (⌘B)", action: model.toggleBypass)
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("arrow.uturn.backward", label: "Undo (⌘Z)") { model.editor?.undo() }
                .disabled(!(model.editor?.canUndo ?? false))
            IconButton("arrow.uturn.forward", label: "Redo (⇧⌘Z)") { model.editor?.redo() }
                .disabled(!(model.editor?.canRedo ?? false))
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("arrow.up.left.and.down.right.magnifyingglass", label: "Fit the flow in view (⇧1)", action: model.fitToView)
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .aeGlass(.floating, radius: 12)
    }
}
