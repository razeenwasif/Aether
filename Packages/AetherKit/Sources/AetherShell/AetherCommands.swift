import AetherGraph
import AppKit
import CanvasUI
import DiffuseBridge
import DiffuseCore
import DiffuseUI
import SwiftUI

/// The menu bar, for the workspace on screen. Undo and Redo go to the flow
/// or the canvas, and Cut, Copy, Paste and Select All to the canvas, unless
/// a text field has the keys, so ⌘Z still undoes typing in a prompt.
public struct AetherCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var diffuse: DiffuseWorkspaceModel { model.diffuse }
    private var canvas: CanvasWorkspaceModel { model.canvas }
    private var onCanvas: Bool { model.active == .canvas }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if onCanvas {
                Button("New Canvas…") { canvas.askForNew() }
                    .keyboardShortcut("n")
                Button("Open…") { canvas.chooseAndOpen() }
                    .keyboardShortcut("o")
                Button("Make a Canvas of a Picture…") { canvas.chooseAndImport() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            } else {
                Button("New Flow") { diffuse.newFlow(template: nil) }
                    .keyboardShortcut("n")
                Menu("New Flow from Template") {
                    ForEach(templates(), id: \.name) { template in
                        Button("\(template.title) — \(template.summary)") { diffuse.newFlow(template: template.name) }
                    }
                }
                Button("Open…") { diffuse.chooseAndOpen() }
                    .keyboardShortcut("o")
            }
            Divider()
            Button("New Project…") { model.newProject() }
            Button("Open Project…") { model.chooseProject() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Open Recent Project") {
                ForEach(model.otherRecentProjects, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { model.openProject(at: url) }
                }
            }
            .disabled(model.otherRecentProjects.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { onCanvas ? canvas.save() : diffuse.save() }
                .keyboardShortcut("s")
            Button("Save As…") { onCanvas ? canvas.saveAs() : diffuse.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            if onCanvas {
                Button("Export…") { canvas.exportPNG() }
                    .keyboardShortcut("e")
                    .disabled(canvas.document == nil)
                Button("Close the Canvas") { canvas.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(canvas.document == nil)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoLabel.map { "Undo \($0)" } ?? "Undo") { textHasKeys ? send("undo:") : model.undo() }
                .keyboardShortcut("z")
            Button(model.redoLabel.map { "Redo \($0)" } ?? "Redo") { textHasKeys ? send("redo:") : model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { pasteboard("cut:") { canvas.copy(cut: true) } }
                .keyboardShortcut("x")
            Button("Copy") { pasteboard("copy:") { canvas.copy() } }
                .keyboardShortcut("c")
            Button("Paste") { pasteboard("paste:") { canvas.paste() } }
                .keyboardShortcut("v")
            Button("Delete") { pasteboard("delete:") { canvas.clearSelected() } }
            Button("Select All") {
                if model.active == .diffuse, diffuse.stage == .graph, !textHasKeys { diffuse.selectAll() } else { pasteboard("selectAll:") { canvas.selectAll() } }
            }
            .keyboardShortcut("a")
            if onCanvas {
                Button("Select Nothing") { canvas.selectNothing() }
                    .keyboardShortcut("d")
                    .disabled(canvas.document == nil)
                Button("Select the Rest") { canvas.invertSelection() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(canvas.document == nil)
            }
        }
        CommandGroup(after: .pasteboard) {
            if model.active == .diffuse {
                Divider()
                Button("Duplicate") { diffuse.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("Bypass") { diffuse.toggleBypass() }
                    .keyboardShortcut("b")
                Button("Move to Trash") { diffuse.askToTrash() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(diffuse.stage != .gallery || diffuse.gallery.picked.isEmpty)
            }
        }
        CommandMenu("Canvas") {
            Button("Fit in View  (f)") { canvas.fit() }
                .disabled(!onCanvas || canvas.document == nil)
            Button("Actual Size  (1)") { canvas.actualSize() }
                .disabled(!onCanvas || canvas.document == nil)
            Button("Zoom In") { canvas.zoom(by: 2) }
                .keyboardShortcut("=")
                .disabled(!onCanvas || canvas.document == nil)
            Button("Zoom Out") { canvas.zoom(by: 0.5) }
                .keyboardShortcut("-")
                .disabled(!onCanvas || canvas.document == nil)
            Divider()
            Button("Add a Layer") { canvas.addLayer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!onCanvas || canvas.document == nil)
            Button("Remove the Layer") { canvas.removeLayer() }
                .disabled(!onCanvas || canvas.document == nil)
            Divider()
            Button("Free Transform") { canvas.startTransform(free: true) }
                .keyboardShortcut("t")
                .disabled(!onCanvas || canvas.document == nil)
            Button("Crop to the Selection") { canvas.cropToSelection() }
                .disabled(!onCanvas || canvas.document?.selected == nil)
            Menu("Turn and Mirror") {
                Button("Turn Left") { canvas.turn(quarters: 3) }
                Button("Turn Right") { canvas.turn(quarters: 1) }
                Button("Turn Round") { canvas.turn(quarters: 2) }
                Divider()
                Button("Mirror Across") { canvas.mirror(across: true) }
                Button("Mirror Down") { canvas.mirror(across: false) }
            }
            .disabled(!onCanvas || canvas.document == nil)
            Button("Resize…") { canvas.askingToResize = true }
                .disabled(!onCanvas || canvas.document == nil)
            Button("Grow ×2 (Scale2x)") { canvas.grow(by: 2) }
                .disabled(!onCanvas || canvas.document == nil)
            Button("Grow ×3 (Scale3x)") { canvas.grow(by: 3) }
                .disabled(!onCanvas || canvas.document == nil)
            Divider()
            Toggle("Show the Pixel Grid  (⇧G)", isOn: Binding(get: { canvas.showGrid }, set: { canvas.showGrid = $0 }))
                .disabled(!onCanvas || canvas.document == nil)
            Toggle("Draw Mirrored Across  (m)", isOn: Binding(get: { canvas.mirrorAcross }, set: { canvas.mirrorAcross = $0 }))
                .disabled(!onCanvas || canvas.document == nil)
            Toggle("Draw Mirrored Down  (⇧M)", isOn: Binding(get: { canvas.mirrorDown }, set: { canvas.mirrorDown = $0 }))
                .disabled(!onCanvas || canvas.document == nil)
            Divider()
            Menu("Frames") {
                Button(canvas.playing ? "Stop  (↩)" : "Play the Frames  (↩)") { canvas.togglePlaying() }
                    .disabled(canvas.frameCount < 2)
                Button("The Frame Before  (,)") { canvas.stepFrame(by: -1) }
                Button("The Frame After  (.)") { canvas.stepFrame(by: 1) }
                Divider()
                Button("New Frame") { canvas.addFrame() }
                Button("Copy the Frame  (⇧N)") { canvas.copyFrame() }
                Button("Remove the Frame") { canvas.removeFrame() }
                    .disabled(canvas.frameCount < 2)
                Divider()
                Toggle("Onion Skin  (⇧O)", isOn: Binding(get: { canvas.onionOn }, set: { canvas.onionOn = $0 }))
            }
            .disabled(!onCanvas || canvas.document == nil)
            Divider()
            Button("All Canvases") { canvas.close() }
                .disabled(!onCanvas || canvas.document == nil)
        }
        CommandMenu("Flow") {
            Button("Generate") { diffuse.run() }
                .keyboardShortcut(.return)
                .disabled(model.active != .diffuse)
            Button("Run to Selected Node") { if let node = diffuse.runTarget { diffuse.runTo(node) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(diffuse.runTarget == nil || diffuse.stage != .graph)
            Button("Cancel Run") { if let run = diffuse.queue.active { diffuse.queue.cancel(run) } }
                .keyboardShortcut(".")
            Divider()
            Button(diffuse.stage == .graph ? "Show the Gallery" : "Show the Graph") { diffuse.toggleStage() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Add a Node…") { diffuse.openLibrary() }
                .disabled(diffuse.stage != .graph)
            Button("Fit the Flow in View") { diffuse.fitToView() }
                .keyboardShortcut("1", modifiers: [.shift])
                .disabled(diffuse.stage != .graph)
            Divider()
            Button("Lock Sealed Files") { diffuse.lockSealed() }
                .disabled(diffuse.sealKey == nil)
            Button("Look for the Server Again") { Task { await diffuse.lookAgain() } }
        }
        CommandGroup(before: .sidebar) {
            Button("Search Tools, Actions and Assets…") { model.toggleOmnibar() }
                .keyboardShortcut("k")
            Divider()
            ForEach(Workspace.allCases) { workspace in
                Button(workspace.title) { model.active = workspace }
                    .keyboardShortcut(workspace.shortcut)
            }
            Divider()
            Button("Show or Hide the Navigator") { model.toggleNavigator() }
                .keyboardShortcut("0")
            Button("Show or Hide the Inspector") { model.toggleInspector() }
                .keyboardShortcut("\\")
            Divider()
        }
    }

    private var textHasKeys: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private func send(_ action: String) {
        NSApp.sendAction(Selector(action), to: nil, from: nil)
    }

    /// An Edit command for the canvas open, unless a text field has the
    /// keys or the canvas isn't on screen: then to whatever has them.
    private func pasteboard(_ action: String, canvas then: () -> Void) {
        if onCanvas, canvas.document != nil, !textHasKeys { then() } else { send(action) }
    }
}
