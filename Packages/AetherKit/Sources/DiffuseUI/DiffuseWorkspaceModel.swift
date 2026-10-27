import AppKit
import DiffuseCore
import LocalAuthentication
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Diffuse workspace holds: the flow open for editing, the
/// catalogue it is checked against, the runs and the server they go to.
@MainActor
@Observable
public final class DiffuseWorkspaceModel {
    public private(set) var editor: FlowEditor?
    public let queue: RunQueue
    public private(set) var library: NodeLibrary
    public private(set) var settings: GatewaySettings
    public var libraryOpen = false
    public var inspectorOpen = true
    /// A short note to the person: something refused or failed.
    public var notice: String?
    /// Where the canvas's visible centre and the pointer are, in flow space,
    /// so a node added from the library lands where the person is looking.
    public var visibleCentre = CGPoint(x: 400, y: 240)
    public var pointer: CGPoint?
    /// Bumped to ask the canvas to fit the whole flow in view.
    public private(set) var fitRequest = 0
    /// Bumped to put the cursor in the library's search field.
    public private(set) var searchRequest = 0

    /// What the stage shows: the flow's graph, or the pictures runs made.
    public enum Stage: Sendable { case graph, gallery }
    public private(set) var stage: Stage = .graph
    public let gallery = Gallery()
    /// Whether the gallery asks for Touch ID or the Mac's password each
    /// time it is shown, as Proton's does.
    public var galleryLockOn: Bool = UserDefaults.standard.object(forKey: "diffuse.galleryLock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(galleryLockOn, forKey: "diffuse.galleryLock") }
    }
    /// Whether the gallery is shut now: nothing of it is read or shown.
    public private(set) var galleryLocked = true
    public private(set) var unlocking = false
    /// Why the last unlock did not open it, in the system's words.
    public private(set) var unlockSaid: String?

    @ObservationIgnored private var key: String?

    public init() {
        let settings = GatewaySettings.current()
        library = NodeLibrary.saved()
        self.settings = settings
        queue = RunQueue(backend: NexusBackend(settings: settings, key: nil))
        openInitialFlow()
        Task { await connect() }
    }

    // MARK: The server

    /// Find the key, reach the gateway, and take its live catalogue.
    public func connect() async {
        if key == nil { key = await Task.detached { GatewayKey.find() }.value }
        queue.use(NexusBackend(settings: settings, key: key))
        await lookAgain()
    }

    public func lookAgain() async {
        if let live = await queue.look() {
            library = live
            editor?.use(live)
        }
    }

    public func update(settings next: GatewaySettings) {
        guard next != settings else { return }
        settings = next
        next.save()
        Task { await connect() }
    }

    // MARK: Files

    /// `~/Documents/Aether/Flows`, where new flows go.
    public var flowsFolder: URL {
        URL.documentsDirectory.appending(path: "Aether/Flows", directoryHint: .isDirectory)
    }

    private func openInitialFlow() {
        if let last = UserDefaults.standard.string(forKey: "diffuse.lastFlow"),
           FileManager.default.fileExists(atPath: last),
           let editor = try? FlowEditor.open(URL(fileURLWithPath: last), library: library) {
            self.editor = editor
            return
        }
        newFlow(template: "textToImage")
    }

    public func newFlow(template: String?) {
        let url = untitledURL()
        do {
            editor = try FlowEditor.create(at: url, template: template, library: library)
            fitRequest += 1
        } catch {
            notice = describe(error)
        }
    }

    public func open(_ url: URL) {
        do {
            editor = try FlowEditor.open(url, library: library)
            UserDefaults.standard.set(url.path, forKey: "diffuse.lastFlow")
            fitRequest += 1
        } catch {
            notice = "Couldn’t open \(url.lastPathComponent): \(describe(error))"
        }
    }

    public func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = flowsFolder
        panel.message = "Choose a .flow.json"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    public func save() {
        guard let editor else { return }
        do {
            try editor.save()
            UserDefaults.standard.set(editor.url.path, forKey: "diffuse.lastFlow")
        } catch {
            notice = "Couldn’t save: \(describe(error))"
        }
    }

    public func saveAs() {
        guard let editor else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = editor.url.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(editor.name).flow.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editor.save(as: url)
            UserDefaults.standard.set(url.path, forKey: "diffuse.lastFlow")
        } catch {
            notice = "Couldn’t save: \(describe(error))"
        }
    }

    private func untitledURL() -> URL { freeURL(named: "Untitled") }

    // MARK: Editing

    public func addNode(_ type: String, at point: CGPoint? = nil) {
        guard let editor else { return }
        let at = point ?? visibleCentre
        if let added = editor.apply([.add(type: type, at: CGPoint(x: at.x - 110, y: at.y - 40))]) {
            editor.selection = Set(added)
        } else {
            notice = editor.refusal
        }
    }

    public func deleteSelection() {
        guard let editor, !editor.selection.isEmpty else { return }
        editor.apply([.remove(ids: Array(editor.selection))])
    }

    public func duplicateSelection() {
        guard let editor, !editor.selection.isEmpty else { return }
        if let added = editor.apply([.duplicate(ids: Array(editor.selection), by: CGSize(width: 32, height: 32))]) {
            editor.selection = Set(added)
        }
    }

    public func toggleBypass() {
        guard let editor, !editor.selection.isEmpty else { return }
        let on = !editor.selection.allSatisfy { editor.flow.node($0)?.isBypassed ?? false }
        editor.apply(editor.selection.sorted().map { .bypass(id: $0, on: on) })
    }

    public func selectAll() {
        guard let editor else { return }
        editor.selection = Set(editor.flow.nodes.map(\.id))
    }

    /// Apply a batch, saying why when the core refuses it.
    @discardableResult
    public func apply(_ ops: [FlowOp]) -> [String]? {
        guard let editor else { return nil }
        let added = editor.apply(ops)
        if added == nil { notice = editor.refusal }
        return added
    }

    public func fitToView() { fitRequest += 1 }

    public func openLibrary() {
        withAnimation(Motion.panel) { libraryOpen = true }
        searchRequest += 1
    }

    // MARK: Running

    public func run() {
        guard let editor else { return }
        if queue.health.state != .serving && queue.health.state != .looking {
            notice = queue.health.message
        }
        queue.run(editor)
    }

    // MARK: The gallery

    public func show(_ next: Stage) {
        guard next != stage else { return }
        let was = stage
        stage = next
        if was == .gallery { shutGallery() }
        if next == .gallery {
            if galleryLockOn {
                Task { await unlockGallery() }
            } else {
                galleryLocked = false
                Task { await refreshGallery() }
            }
        }
    }

    public func toggleStage() { show(stage == .graph ? .gallery : .graph) }

    /// Ask for Touch ID or the Mac's password, then open the gallery.
    public func unlockGallery() async {
        guard galleryLocked, !unlocking else { return }
        unlocking = true
        unlockSaid = nil
        defer { unlocking = false }
        let context = LAContext()
        var why: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &why) else {
            unlockSaid = why?.localizedDescription ?? "This Mac can’t ask for Touch ID or its password."
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "see the images Diffuse has made")
        } catch {
            unlockSaid = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
            return
        }
        // Left while the system was asking: stay shut.
        guard stage == .gallery else { return }
        galleryLocked = false
        await refreshGallery()
    }

    /// The gallery left: shut again, and its pictures let go.
    private func shutGallery() {
        galleryLocked = true
        unlockSaid = nil
        gallery.forget()
        Thumbnails.shared.forget()
    }

    /// The folders whose `outputs/` the gallery shows: where new flows go,
    /// and the open flow's own folder.
    public var galleryRoots: [URL] {
        var roots = [flowsFolder.standardizedFileURL]
        if let folder = editor?.url.deletingLastPathComponent().standardizedFileURL, !roots.contains(folder) {
            roots.append(folder)
        }
        return roots
    }

    public func refreshGallery() async {
        guard stage == .gallery, !galleryLocked else { return }
        await gallery.refresh(roots: galleryRoots)
    }

    /// A new flow from the graph forge wrote into `picture`, named after it.
    public func openGraph(of url: URL) async {
        guard let head = await gallery.head(for: url) ?? PictureHead.read(url), let graph = head.graphJSON else {
            notice = "\(url.lastPathComponent) holds no graph: it was not made by a flow, or not by forge."
            return
        }
        let stem = url.deletingPathExtension().lastPathComponent
        do {
            editor = try FlowEditor.create(at: freeURL(named: stem), fromGraph: graph, library: library)
            show(.graph)
            fitRequest += 1
        } catch {
            notice = "Couldn’t open its graph: \(describe(error))"
        }
    }

    /// The flow a picture's folder is named after, if it is at hand.
    public func flowFile(for picture: GalleryPicture) -> URL? {
        for root in galleryRoots {
            let url = root.appending(path: "\(picture.flow).flow.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func openFlow(at url: URL) {
        open(url)
        show(.graph)
    }

    public func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Whether the gallery is asking before it moves pictures to the Trash.
    public var askingTrash = false

    public func askToTrash() {
        if stage == .gallery, !gallery.picked.isEmpty { askingTrash = true }
    }

    /// Move the pictures chosen to the Trash.
    public func trashPicked() {
        let failed = gallery.trash(gallery.picked)
        if failed > 0 { notice = failed == 1 ? "One image couldn’t be moved to the Trash." : "\(failed) images couldn’t be moved to the Trash." }
    }

    /// A file in the flows folder named `stem`, numbered when one is there.
    private func freeURL(named stem: String) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "\(stem).flow.json" : "\(stem) \(n).flow.json"
            let url = flowsFolder.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    // MARK: Keys

    /// The stage's own keys: ⌫ deletes the selected nodes or asks to move
    /// the chosen pictures to the Trash, esc lets go of them, ⇥ opens the
    /// node library. Answers whether the key was used. Read from every key
    /// the window gets, so they work wherever its focus is, except in text.
    public func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText),
              event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        else { return false }
        switch (event.keyCode, stage) {
        case (51, .graph), (117, .graph):
            guard let editor, !editor.selection.isEmpty else { return false }
            deleteSelection()
        case (51, .gallery), (117, .gallery):
            guard !gallery.picked.isEmpty else { return false }
            askToTrash()
        case (53, .graph):
            guard let editor, !editor.selection.isEmpty else { return false }
            editor.selection.removeAll()
        case (53, .gallery):
            guard !gallery.picked.isEmpty else { return false }
            gallery.clearPicks()
        case (48, .graph):
            openLibrary()
        default:
            return false
        }
        return true
    }

    /// The newest output a run made at `node`, if any.
    public func latestOutput(at node: String) -> RunItem.Output? {
        for run in queue.runs {
            if let output = run.outputs.last(where: { $0.node == node }) { return output }
        }
        return nil
    }
}

import AetherDesign
