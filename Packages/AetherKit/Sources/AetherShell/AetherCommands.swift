import AppKit
import DiffuseBridge
import DiffuseCore
import DiffuseUI
import SwiftUI

/// The menu bar. Undo and Redo go to the flow unless a text field has the
/// keys, so ⌘Z still undoes typing in a prompt.
public struct AetherCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var diffuse: DiffuseWorkspaceModel { model.diffuse }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
        CommandGroup(replacing: .saveItem) {
            Button("Save") { diffuse.save() }
                .keyboardShortcut("s")
            Button("Save As…") { diffuse.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { textHasKeys ? send("undo:") : diffuse.editor?.undo() }
                .keyboardShortcut("z")
            Button("Redo") { textHasKeys ? send("redo:") : diffuse.editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate") { diffuse.duplicateSelection() }
                .keyboardShortcut("d")
            Button("Bypass") { diffuse.toggleBypass() }
                .keyboardShortcut("b")
            Button("Move to Trash") { diffuse.askToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(diffuse.stage != .gallery || diffuse.gallery.picked.isEmpty)
        }
        CommandMenu("Flow") {
            Button("Generate") { model.run() }
                .keyboardShortcut(.return)
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
}
