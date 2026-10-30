import AetherGraph
import AppKit
import CanvasUI
import DiffuseBridge
import DiffuseCore
import DiffuseUI
import ModelCore
import ModelUI
import SwiftUI

/// The menu bar, for the workspace on screen. Undo and Redo go to the flow,
/// the canvas or the scene, and Cut, Copy, Paste and Select All to the canvas, unless
/// a text field has the keys, so ⌘Z still undoes typing in a prompt.
public struct AetherCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var diffuse: DiffuseWorkspaceModel { model.diffuse }
    private var canvas: CanvasWorkspaceModel { model.canvas }
    private var onCanvas: Bool { model.active == .canvas }
    private var modeling: ModelWorkspaceModel { model.modeling }
    private var onModel: Bool { model.active == .model }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if onCanvas {
                Button("New Canvas…") { canvas.askForNew() }
                    .keyboardShortcut("n")
                Button("Open…") { canvas.chooseAndOpen() }
                    .keyboardShortcut("o")
                Button("Make a Canvas of a Picture…") { canvas.chooseAndImport() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            } else if onModel {
                Button("New Scene…") { modeling.askForNew() }
                    .keyboardShortcut("n")
                Button("Open…") { modeling.chooseAndOpen() }
                    .keyboardShortcut("o")
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
            Button("Save") { onModel ? modeling.saveNow() : onCanvas ? canvas.save() : model.active == .game ? model.game.saveNow() : diffuse.save() }
                .keyboardShortcut("s")
            Button("Save As…") { onCanvas ? canvas.saveAs() : diffuse.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                // A scene is saved as it's edited, beside its meshes.
                .disabled(onModel)
            if onModel {
                Button("Close the Scene") { modeling.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(modeling.document == nil)
            }
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
            Button("Delete") {
                if onModel, !textHasKeys, modeling.editing != nil { modeling.deleteChosen() }
                else if onModel, modeling.selected != nil, !textHasKeys { modeling.removeSelected() }
                else { pasteboard("delete:") { canvas.clearSelected() } }
            }
            Button("Select All") {
                if onModel, !textHasKeys, let edit = modeling.editing { return edit.chooseAll() }
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
        CommandMenu("Scene") {
            Button("Render  (⌘↩)") { modeling.render() }
                .disabled(!onModel || modeling.document == nil)
            Button(modeling.renderOpen ? "Hide the Render" : "Show the Render") { modeling.toggleRenderDrawer() }
                .disabled(!onModel || modeling.document == nil)
            Picker("Render With", selection: Binding(get: { modeling.renderEngine }, set: { modeling.renderEngine = $0 })) {
                ForEach(RenderEngine.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!onModel || modeling.document == nil)
            Toggle("Denoise Path-Traced Renders", isOn: Binding(get: { modeling.renderDenoise }, set: { modeling.renderDenoise = $0 }))
                .disabled(!onModel || modeling.document == nil)
            Divider()
            Menu("Add") {
                ForEach(SceneAddition.allCases) { addition in
                    Button(addition.title) { modeling.add(addition) }
                }
            }
            .disabled(!onModel || modeling.document == nil)
            Divider()
            Button("Frame the Object  (f)") { modeling.frameSelected() }
                .disabled(!onModel || modeling.document == nil)
            Button("Frame Everything") { modeling.frameAll() }
                .disabled(!onModel || modeling.document == nil)
            Divider()
            Button("New Material") { modeling.newMaterial() }
                .disabled(!onModel || modeling.selectedNode == nil || modeling.editing != nil)
            Menu("Add a Layer") {
                ForEach(LayerPattern.allCases) { pattern in
                    Button(pattern.title) { modeling.addLayer(pattern) }
                }
            }
            .disabled(!onModel || modeling.selectedNode == nil || modeling.editing != nil)
            Button(modeling.graphOpen ? "Hide the Material Graph" : "Show the Material Graph") { modeling.toggleGraph() }
                .disabled(!onModel || modeling.document == nil)
            Button("Remove Unworn Materials") { modeling.removeUnwornMaterials() }
                .disabled(!onModel || modeling.document == nil)
            Divider()
            Button(modeling.editing == nil ? "Edit the Mesh  (⇥)" : "Back to the Objects  (⇥)") { modeling.toggleEdit() }
                .disabled(!onModel || (modeling.editing == nil && !modeling.canEdit))
            Picker("Choose", selection: Binding(get: { modeling.editing?.part ?? .faces }, set: { modeling.showPart($0) })) {
                ForEach(EditPart.allCases) { part in Text("\(part.title)  (\(part.key))").tag(part) }
            }
            .disabled(!onModel || modeling.editing == nil)
            Button("Extrude  (e)") { modeling.extrudeChosen() }
                .disabled(!onModel || modeling.editing == nil)
            Button("Inset  (i)") { modeling.insetChosen() }
                .disabled(!onModel || modeling.editing == nil)
            Button("Bevel  (b)") { modeling.bevelChosen() }
                .disabled(!onModel || modeling.editing == nil)
            Button("Loop Cut") { modeling.loopCutChosen() }
                .keyboardShortcut("r")
                .disabled(!onModel || modeling.editing == nil)
            Divider()
            Button("All Scenes") { modeling.close() }
                .disabled(!onModel || modeling.document == nil)
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
            // ⌘↩ is each workspace's one verb: Generate here, and Render in
            // Model, through the same item, as two items can't share a key.
            Button("Generate") { model.run() }
                .keyboardShortcut(.return)
                .disabled(model.active != .diffuse && !(model.active == .model && modeling.document != nil))
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
