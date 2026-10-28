import AetherGraph
import AppKit
import CanvasCore
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the pointer does on the canvas.
public enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case brush, pencil, eraser, fill, pick, line, rect, ellipse, select, wand, move

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .brush: "Brush"
        case .pencil: "Pencil"
        case .eraser: "Eraser"
        case .fill: "Fill"
        case .pick: "Pick a colour"
        case .line: "Line"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .select: "Select"
        case .wand: "Magic wand"
        case .move: "Move"
        }
    }

    public var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .pencil: "pencil"
        case .eraser: "eraser"
        case .fill: "drop"
        case .pick: "eyedropper"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .select: "rectangle.dashed"
        case .wand: "wand.and.stars"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    /// Its key, as Proton's: b and n are the brush and the pencil, which is
    /// which depending on the canvas.
    public var key: String {
        switch self {
        case .brush, .pencil: "b n"
        case .eraser: "e"
        case .fill: "g"
        case .pick: "i"
        case .line: "l"
        case .rect: "r"
        case .ellipse: "o"
        case .select: "s"
        case .wand: "w"
        case .move: "v"
        }
    }

    var shape: CanvasShape? {
        switch self {
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        default: nil
        }
    }
}

/// The shapes the select tool makes, in the order s steps through them.
public enum CanvasSelectShape: String, CaseIterable, Sendable {
    case rect, ellipse, lasso

    public var title: String {
        switch self {
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .lasso: "Lasso"
        }
    }

    public var symbol: String {
        switch self {
        case .rect: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .lasso: "lasso"
        }
    }
}

/// What is selected of a layer, lifted and being moved — scaled and turned
/// too when `free` — until it is kept as one op or left.
public struct CanvasMoving {
    public var layer: UInt32
    /// Where it was lifted from, in canvas pixels.
    public var rect: CGRect
    public var transform: CanvasTransform
    /// ⌘T's: with handles, and kept with ↩ rather than when let go.
    public var free: Bool
    /// What was lifted, premultiplied.
    public var image: CGImage
}

/// Where the canvas sits in the stage: points per canvas pixel, and where
/// its top-left corner is, in points from the stage's.
public struct CanvasViewport: Equatable, Sendable {
    public static let least: CGFloat = 0.05
    public static let most: CGFloat = 64

    public var scale: CGFloat = 1
    public var offset: CGPoint = .zero

    public func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    public func stagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    /// Zoomed by `factor`, keeping the canvas pixel under `p` where it is.
    public mutating func zoom(by factor: CGFloat, around p: CGPoint) {
        let under = canvasPoint(p)
        scale = min(Self.most, max(Self.least, scale * factor))
        offset = CGPoint(x: p.x - under.x * scale, y: p.y - under.y * scale)
    }
}

/// A canvas in the Canvases folder.
public struct CanvasFile: Identifiable, Hashable, Sendable {
    public var url: URL
    public var preset: CanvasPreset
    public var width: Int
    public var height: Int
    public var modified: Date
    public var id: URL { url }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    /// The `.canvas` folder at `url`, read from its `canvas.json`.
    static func read(_ url: URL) -> CanvasFile? {
        struct Manifest: Decodable {
            var preset: CanvasPreset
            var size: [Int]
        }
        guard let data = try? Data(contentsOf: url.appending(path: "canvas.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.size.count == 2 else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.appending(path: "canvas.json").path)[.modificationDate] as? Date) ?? .distantPast
        return CanvasFile(url: url, preset: manifest.preset, width: manifest.size[0], height: manifest.size[1], modified: modified)
    }
}

/// The Canvas workspace: the canvas open, the tool and its settings, the
/// layer drawn on, and the canvases in `~/Documents/Aether/Canvases`.
@MainActor
@Observable
public final class CanvasWorkspaceModel {
    public private(set) var document: CanvasDocument?
    public var tool: CanvasTool = .brush {
        // Another tool keeps what is being moved, as Proton does.
        didSet { if tool != oldValue { finishTransform() } }
    }
    public var color = RGBA(24, 24, 28)
    /// Colours used lately, newest first.
    public private(set) var recent: [RGBA] = []
    public var brush = CanvasBrush()
    public var tip = CanvasTip(size: 1)
    public var pixelPerfect = true
    public var shapeFilled = false
    public var tolerance: UInt8 = 0
    public var contiguous = true
    /// The select tool's shape; how a selection joins what is selected,
    /// unless ⇧ or ⌥ say; and how many pixels its edge is feathered by.
    public var selectShape: CanvasSelectShape = .rect
    public var selectMode: CanvasSelectMode = .replace
    public var feather: UInt32 = 0
    /// The magic wand's own.
    public var wandTolerance: UInt8 = 16
    public var wandContiguous = true
    public var wandDiagonal = false
    /// What is being moved, until it is kept or left.
    public internal(set) var moving: CanvasMoving?
    /// The pixel grid (⇧G), drawn once a pixel is six points or more.
    public var showGrid = false
    /// Drawing mirrored across the canvas's middle (m) and down it (⇧M):
    /// the pencil's tip and shapes, as Proton's are.
    public var mirrorAcross = false
    public var mirrorDown = false
    /// The palette's swatch last chosen: what Recolour changes.
    public var swatch: Int?
    /// The resize form.
    public var askingToResize = false
    /// The system clipboard's change count when this canvas last put its
    /// copy there: pasting it again pastes the copy where it was.
    @ObservationIgnored private var ownClipboard: Int?
    /// The system's clipboard; tests use one of their own.
    @ObservationIgnored public var clipboard = NSPasteboard.general
    /// The layer drawn on.
    public var layer: UInt32?
    public var viewport = CanvasViewport()
    /// The stage's size, for fitting the canvas in it.
    public var stageSize: CGSize = .zero
    public var navigatorOpen = true
    public var inspectorOpen = true
    public var notice: String?
    public private(set) var canvases: [CanvasFile] = []
    /// The new canvas form, on the home page or in a sheet.
    public var askingForNew = false
    /// Leaving a canvas with changes not saved: what was going to happen.
    public var leaving: (() -> Void)?
    /// Space held: the pointer pans.
    public var panning = false
    /// Where the pointer is on the canvas, in pixels, while it's over it.
    public var pointer: CGPoint?

    /// Where canvases go: the project's `Canvases/`.
    public private(set) var folder: URL

    /// The project the canvas belongs to: its links, and every document's
    /// steps in one history. Set by the window; tests may leave it out.
    public var project: ProjectGraph? {
        didSet { listen() }
    }
    @ObservationIgnored var listening: Listening?
    /// The project change to make with the next step, given what it did.
    @ObservationIgnored var attaching: ((CanvasDocument.Applied) -> AetherGraph.Transaction?)?
    /// A linked layer taking a version, or an asset being placed, while its
    /// bytes are read.
    @ObservationIgnored public internal(set) var following: Task<Void, Never>?
    /// The canvas being published after a save.
    @ObservationIgnored public internal(set) var publishing: Task<Void, Never>?
    /// Where Show the Source goes: the asset's document, in its workspace.
    @ObservationIgnored public var showSource: ((Asset) -> Void)?

    /// Where settings kept between launches go; tests use their own.
    @ObservationIgnored let defaults: UserDefaults

    public init(folder: URL = CanvasWorkspaceModel.defaultFolder, defaults: UserDefaults = .standard) {
        self.folder = folder
        self.defaults = defaults
        refreshList()
        loadOnion()
    }

    /// `~/Documents/Aether/Canvases`, where canvases go.
    public nonisolated static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "Aether/Canvases", directoryHint: .isDirectory)
    }

    public static let sizes: [CanvasPreset: [(Int, Int)]] = [
        .pixel: [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256)],
        .paint: [(1024, 1024), (2048, 2048), (1920, 1080), (2560, 1440), (4096, 4096)],
    ]

    // MARK: Canvases

    /// The new canvas form: on the home page, or a sheet over the canvas.
    public func askForNew() {
        askingForNew = true
    }

    public func refreshList() {
        let fm = FileManager.default
        let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        canvases = found.filter { $0.pathExtension == "canvas" }.compactMap(CanvasFile.read).sorted { $0.modified > $1.modified }
    }

    /// A new canvas named `name` (made unique in the folder), written at once
    /// so it is in the list, and opened.
    public func newCanvas(named name: String, preset: CanvasPreset, width: Int, height: Int) {
        leave {
            do {
                let doc = try CanvasDocument.create(width: width, height: height, preset: preset, at: self.unique(name))
                try doc.save()
                self.show(doc)
                self.refreshList()
            } catch {
                self.notice = "Couldn’t make the canvas: \(Self.describe(error))"
            }
        }
    }

    public func open(_ url: URL) {
        guard url != document?.url else { return }
        leave {
            do {
                self.show(try CanvasDocument.open(url))
            } catch {
                self.notice = "Couldn’t open \(url.lastPathComponent): \(Self.describe(error))"
            }
        }
    }

    public func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open a Canvas"
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "canvas" else {
            notice = "\(url.lastPathComponent) isn’t a canvas: a canvas is a folder ending in .canvas."
            return
        }
        open(url)
    }

    /// Make a canvas of a picture chosen: a PNG, a Photoshop or an Aseprite
    /// file, its layers kept.
    public func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Make a Canvas of a Picture"
        panel.allowedContentTypes = [.png, .jpeg, UTType("com.adobe.photoshop-image") ?? .image, UTType(filenameExtension: "aseprite") ?? .data, UTType(filenameExtension: "ase") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            receive(try Data(contentsOf: url), named: url.lastPathComponent, keep: true)
        }
        catch {
            notice = "Couldn’t read \(url.lastPathComponent): \(Self.describe(error))"
        }
    }

    /// A picture as a new canvas named after it: written into the folder at
    /// once when `keep`, otherwise only when saved (as for a sealed picture,
    /// since canvases are saved plain).
    /// Linking `asset`, the layer follows it: a new version replaces it.
    public func receive(_ bytes: Data, named name: String, keep: Bool, linking asset: Asset? = nil) {
        leave {
            let stem = (name as NSString).deletingPathExtension
            do {
                let doc = try CanvasDocument.importing(CanvasPicture.readable(bytes), named: name, at: self.unique(stem.isEmpty ? "Picture" : stem))
                if keep { try doc.save() }
                self.show(doc)
                self.refreshList()
                // Part of making the canvas, so not an undo step.
                if let asset, keep, let project = self.project, let layer = doc.state.layers.first {
                    let path = project.path(of: doc.url)
                    try project.apply(AetherGraph.Transaction([project.linkOp(asset.id, into: path, slot: Slot.layer(layer.id), by: .canvas)], origin: .canvas, label: "Link \(asset.name)", document: path, undoable: false))
                }
                if !keep {
                    self.notice = "\(doc.name) came from a sealed picture: it isn’t written until you save it, and canvases are saved plain."
                }
            } catch {
                self.notice = "Couldn’t make a canvas of \(name): \(Self.describe(error))"
            }
        }
    }

    public func save() {
        guard let document else { return }
        finishTransform()
        do {
            try document.save()
            if let path = documentPath { project?.documentSaved(path) }
            refreshList()
            publishIfUsed()
        } catch {
            notice = "Couldn’t save \(document.name): \(Self.describe(error))"
        }
    }

    public func saveAs() {
        guard let document else { return }
        finishTransform()
        let panel = NSSavePanel()
        panel.title = "Save the Canvas As"
        panel.directoryURL = folder
        panel.nameFieldStringValue = document.name
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "canvas" { url = url.appendingPathExtension("canvas") }
        do {
            let was = documentPath
            try document.save(as: url)
            if let project, let was { project.move(document: was, to: project.path(of: url), by: .canvas) }
            if let path = documentPath { project?.documentSaved(path) }
            refreshList()
        } catch {
            notice = "Couldn’t save \(url.lastPathComponent): \(Self.describe(error))"
        }
    }

    /// Everything laid together, written as a PNG.
    public func exportPNG() {
        guard let document else { return }
        finishTransform()
        let panel = NSSavePanel()
        panel.title = "Export a PNG"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = document.name + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.png().write(to: url, options: .atomic)
        } catch {
            notice = "Couldn’t export \(url.lastPathComponent): \(Self.describe(error))"
        }
    }

    /// Another project's canvases: the canvas open is shut without asking
    /// (the window asked about every workspace first), and the list is the
    /// new folder's.
    public func switchFolder(to url: URL) {
        stop()
        moving = nil
        leaving = nil
        letGo()
        document = nil
        layer = nil
        folder = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        refreshList()
    }

    /// Back to the home page.
    public func close() {
        leave {
            self.stop()
            self.letGo()
            self.document = nil
            self.layer = nil
            self.refreshList()
        }
    }

    /// Do `then`, but first ask what to do with changes not saved.
    func leave(then: @escaping () -> Void) {
        finishTransform()
        guard let document, document.state.dirty else { return then() }
        leaving = then
    }

    /// The answer to leaving with changes: save them, drop them, or stay.
    public func answerLeaving(save: Bool?) {
        guard let then = leaving else { return }
        leaving = nil
        guard let save else { return }
        if save {
            self.save()
            if document?.state.dirty == true { return }
        }
        then()
    }

    private func show(_ doc: CanvasDocument) {
        stop()
        moving = nil
        swatch = nil
        thumbs = [:]
        if document !== doc { letGo() }
        document = doc
        doc.onStep = { [weak self, weak doc] label, applied in self?.stepped(label, applied, in: doc) }
        applyOnion()
        layer = doc.state.layers.last?.id
        if doc.state.preset == .pixel, tool == .brush { tool = .pencil }
        if doc.state.preset == .paint, tool == .pencil { tool = .brush }
        if doc.state.preset == .pixel, recent.isEmpty, let first = doc.state.palette.first { color = RGBA(first) }
        fit()
        catchUp()
    }

    /// `name`.canvas in the folder, or `name 2`.canvas and on, whichever isn't taken.
    func unique(_ name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        var candidate = folder.appending(path: "\(base).canvas", directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(n).canvas", directoryHint: .isDirectory)
            n += 1
        }
        return candidate
    }

    // MARK: Layers

    public var currentLayer: CanvasLayer? {
        guard let document else { return nil }
        return document.state.layers.first { $0.id == layer } ?? document.state.layers.last
    }

    public func addLayer() {
        guard let document else { return }
        let place = currentLayer.flatMap { l in document.state.layers.firstIndex { $0.id == l.id } }.map { UInt32($0 + 1) }
        if let made = document.apply(.addLayer(name: "Layer \(document.state.layers.count + 1)", at: place), label: "Add a layer")?.made {
            layer = made
        } else {
            notice = document.refusal
        }
    }

    public func removeLayer() {
        guard let document, let current = currentLayer else { return }
        guard document.state.layers.count > 1 else {
            notice = "A canvas keeps at least one layer."
            return
        }
        let index = document.state.layers.firstIndex { $0.id == current.id } ?? 0
        if document.apply(.removeLayer(current.id), label: "Remove \(current.name)") != nil {
            let layers = document.state.layers
            layer = layers[max(0, min(index - 1, layers.count - 1))].id
        } else {
            notice = document.refusal
        }
    }

    /// The layer drawn on, one place up (toward the top) or down.
    public func moveLayer(up: Bool) {
        guard let document, let current = currentLayer, let index = document.state.layers.firstIndex(where: { $0.id == current.id }) else { return }
        let to = up ? index + 1 : index - 1
        guard to >= 0, to < document.state.layers.count else { return }
        change(.moveLayer(current.id, to: UInt32(to)), label: up ? "Move up" : "Move down")
    }

    public func setLayer(_ id: UInt32, name: String? = nil, opacity: UInt8? = nil, blend: CanvasBlend? = nil, hidden: Bool? = nil, locked: Bool? = nil, alphaLock: Bool? = nil, label: String) {
        change(.setLayer(id, name: name, opacity: opacity, blend: blend, hidden: hidden, locked: locked, alphaLock: alphaLock), label: label)
    }

    /// Apply a change, saying why when it is refused. What is being moved is
    /// kept first: it is what the person sees.
    public func change(_ op: CanvasOp, label: String) {
        guard let document else { return }
        stop()
        finishTransform()
        if document.apply(op, label: label) == nil { notice = document.refusal }
    }

    /// Undo the canvas's newest step, its own or a project step made in it
    /// (a link kept or let go); while something is being moved, that move
    /// is left instead.
    public func undo() {
        if moving != nil { return leaveTransform() }
        guard let document else { return }
        stop()
        if let project { project.undo(in: project.path(of: document.url)) { document.undo() } } else { document.undo() }
    }

    public func redo() {
        if moving != nil { return leaveTransform() }
        guard let document else { return }
        stop()
        if let project { project.redo(in: project.path(of: document.url)) { document.redo() } } else { document.redo() }
    }

    /// What ⌘Z would undo, and ⇧⌘Z redo, for the Edit menu.
    public var undoLabel: String? { project.flatMap { p in documentPath.flatMap { p.undoLabel(in: $0) } } ?? document?.state.undo }
    public var redoLabel: String? {
        guard let project else { return document?.state.redo }
        return documentPath.flatMap { project.redoLabel(in: $0) }
    }

    // MARK: Selections

    /// A selection made: `area` joined to what is selected by `mode`.
    public func select(_ area: CanvasArea, mode: CanvasSelectMode = .replace) {
        guard let document else { return }
        let label = switch area {
        case .all: "Select all"
        case .nothing: "Select nothing"
        case .invert: "Select the rest"
        default: "Select"
        }
        change(.select(area, mode: mode, feather: feather, smooth: document.state.preset == .paint), label: label)
    }

    public func selectAll() { select(.all) }
    public func selectNothing() { select(.nothing) }
    public func invertSelection() { select(.invert) }

    /// How a selection joins what is selected: ⇧ adds, ⌥ takes away, both
    /// keep only where both are; otherwise as the inspector says.
    func mode(shift: Bool, option: Bool) -> CanvasSelectMode {
        shift && option ? .intersect : shift ? .add : option ? .subtract : selectMode
    }

    /// A selection dragged from `a` to `b` (canvas points) — or a lasso
    /// through `points` — made. A click selects nothing, as Proton's does.
    public func selectDragged(from a: CGPoint, to b: CGPoint, lasso points: [CGPoint], mode: CanvasSelectMode) {
        let small = hypot((b.x - a.x) * viewport.scale, (b.y - a.y) * viewport.scale) < 3
        if selectShape == .lasso {
            if points.count >= 3, !small {
                select(.lasso(points.flatMap { [Int32(($0.x * 256).rounded()), Int32(($0.y * 256).rounded())] }), mode: mode)
            } else if mode == .replace {
                select(.nothing)
            }
            return
        }
        guard !small else {
            if mode == .replace { select(.nothing) }
            return
        }
        let rect = Self.pixelRect(a, b)
        select(selectShape == .ellipse ? .ellipse(rect) : .rect(rect), mode: mode)
    }

    /// The magic wand at a canvas point, on the layer drawn on.
    public func selectLike(at c: CGPoint, mode: CanvasSelectMode) {
        guard let layer = currentLayer else { return }
        select(.wand(layer: cel(layer), x: Int32(floor(c.x)), y: Int32(floor(c.y)), tolerance: wandTolerance, contiguous: wandContiguous, diagonal: wandDiagonal), mode: mode)
    }

    /// The whole pixels from one point's to another's, both in: left, top,
    /// width, height.
    static func pixelRect(_ a: CGPoint, _ b: CGPoint) -> [Int32] {
        let (x0, y0) = (floor(min(a.x, b.x)), floor(min(a.y, b.y)))
        let (x1, y1) = (floor(max(a.x, b.x)), floor(max(a.y, b.y)))
        return [Int32(x0), Int32(y0), Int32(x1 - x0 + 1), Int32(y1 - y0 + 1)]
    }

    /// ⌫: what is selected of the layer cleared — all of it, with nothing
    /// selected.
    public func clearSelected() {
        guard let layer = currentLayer else { return }
        if let refusal = linkedRefusal(layer) { return notice = refusal }
        change(.clear(layer: cel(layer)), label: "Clear")
    }

    // MARK: The clipboard

    /// What is selected of the layer — all of it, with nothing selected —
    /// copied, and put on the system's clipboard as a PNG; cut, cleared too.
    public func copy(cut: Bool = false) {
        guard let document, let layer = currentLayer else { return }
        finishTransform()
        if cut, let refusal = linkedRefusal(layer) { return notice = refusal }
        guard document.apply(.copy(layer: cel(layer), cut: cut), label: cut ? "Cut" : "Copy") != nil else {
            notice = document.refusal
            return
        }
        guard let png = document.clipPNG() else {
            notice = "There’s nothing there to copy."
            return
        }
        let board = clipboard
        board.clearContents()
        board.setData(png, forType: .png)
        ownClipboard = board.changeCount
    }

    /// ⌘V: a picture another app copied, brought in as a layer — or, when
    /// the clipboard holds this canvas's own copy or no picture, that copy
    /// pasted as a layer where it was.
    public func paste() {
        guard let document else { return }
        finishTransform()
        let board = clipboard
        if board.changeCount != ownClipboard, let (bytes, name) = CanvasPicture.on(board) {
            return bringIn(bytes, named: name)
        }
        if let made = document.apply(.paste(above: currentLayer?.id, frame: UInt32(frame)), label: "Paste")?.made {
            layer = made
        } else {
            notice = document.refusal == "nothing is copied" ? "Nothing’s copied yet: select something and copy it (⌘C)." : document.refusal
        }
    }

    /// A picture brought in as a layer over the one drawn on — pasted, or
    /// dropped on the canvas — and drawn on next.
    public func bringIn(_ bytes: Data, named name: String) {
        guard let document else { return }
        finishTransform()
        let stem = (name as NSString).deletingPathExtension
        guard let applied = document.bringIn(CanvasPicture.readable(bytes), named: stem.isEmpty ? "Pasted" : stem, above: currentLayer?.id) else {
            notice = document.refusal
            return
        }
        if let made = applied.made { layer = made }
        if let notes = applied.notes, !notes.isEmpty { notice = notes.joined(separator: "; ") }
    }

    // MARK: Moving, scaling and turning

    /// What is selected of the layer — all of it, with nothing selected —
    /// lifted to be moved: shown where it is going, what is left of the
    /// layer under it. `free`, with handles to scale and turn it (⌘T).
    /// Whether there was anything to lift.
    @discardableResult
    public func startTransform(free: Bool) -> Bool {
        if var moving {
            if free, !moving.free {
                moving.free = true
                self.moving = moving
            }
            return true
        }
        guard let document, let layer = currentLayer else { return false }
        guard !layer.locked else {
            notice = "\(layer.name) is locked."
            return false
        }
        if let refusal = linkedRefusal(layer) {
            notice = refusal
            return false
        }
        guard let lifted = document.lift(cel(layer)) else {
            notice = "There’s nothing on \(layer.name) to move."
            return false
        }
        document.preview(.clear(layer: cel(layer)))
        moving = CanvasMoving(layer: cel(layer), rect: lifted.rect, transform: CanvasTransform(lifted.rect), free: free, image: lifted.image)
        return true
    }

    /// What is being moved kept, as one undo step: a move by whole pixels,
    /// or a transform sampled by the nearest pixel on a pixel canvas and
    /// the four about it on a painting.
    public func finishTransform() {
        guard let moving, let document else { return }
        self.moving = nil
        document.clearPreview()
        let t = moving.transform
        guard !t.isIdentity else { return }
        let label = t.isWholeMove ? "Move" : "Transform"
        let op: CanvasOp = if let made = t.op(moving.rect, width: document.width, height: document.height) {
            .transform(layer: moving.layer, bounds: made.bounds, inverse: made.inverse, smooth: document.state.preset == .paint && !t.isWholeMove)
        } else {
            // Moved wholly off the canvas, or squashed to nothing: gone.
            .clear(layer: moving.layer)
        }
        if document.apply(op, label: label) == nil { notice = document.refusal }
    }

    /// What is being moved left: everything as it was.
    public func leaveTransform() {
        guard moving != nil else { return }
        moving = nil
        document?.clearPreview()
    }

    /// What is being moved mirrored across, or down.
    public func mirrorMoving(across: Bool) {
        guard var moving else { return }
        if across { moving.transform.sx = -moving.transform.sx } else { moving.transform.sy = -moving.transform.sy }
        self.moving = moving
    }

    // MARK: The whole canvas

    /// The canvas turned a quarter clockwise or back, or half round.
    public func turn(quarters: UInt8) {
        change(.orient(turns: quarters), label: quarters == 1 ? "Turn right" : quarters == 3 ? "Turn left" : "Turn round")
        fit()
    }

    /// The canvas mirrored across (left to right) or down.
    public func mirror(across: Bool) {
        change(across ? .orient(turns: 0, flip: true) : .orient(turns: 2, flip: true), label: across ? "Mirror across" : "Mirror down")
    }

    /// The canvas cut to the rectangle round what is selected.
    public func cropToSelection() {
        guard let rect = document?.selected else {
            notice = "Select something to crop to."
            return
        }
        change(.crop([Int32(rect.minX), Int32(rect.minY), Int32(rect.width), Int32(rect.height)]), label: "Crop")
        fit()
    }

    /// The whole canvas made `width` by `height`: by the nearest pixel on a
    /// pixel canvas, weighed on a painting.
    public func resizeCanvas(width: Int, height: Int) {
        guard let document else { return }
        let preset = document.state.preset
        guard (1...preset.most).contains(width), (1...preset.most).contains(height) else {
            notice = "A \(preset.title) canvas is 1 to \(preset.most) pixels a side."
            return
        }
        change(.resize(width: UInt32(width), height: UInt32(height), smooth: preset == .paint), label: "Resize")
        fit()
    }

    // MARK: Frames

    /// The frame shown and drawn in, from 0.
    public var frame: Int { document?.frame ?? 0 }
    public var frameCount: Int { document?.state.frames.count ?? 1 }
    public var tags: [CanvasTag] { document?.state.tags ?? [] }

    /// A layer's cel in the frame shown: what an edit of its pixels names.
    public func cel(_ layer: CanvasLayer) -> UInt32 { CanvasCel.id(layer: layer.id, frame: frame) }

    /// Show frame `f` (held to the frames there are), keeping what is being
    /// moved first. Showing one stops playing, unless it is playing that
    /// shows it.
    public func showFrame(_ f: Int, keepPlaying: Bool = false) {
        guard let document else { return }
        if !keepPlaying { stop() }
        finishTransform()
        document.show(frame: max(0, min(frameCount - 1, f)))
    }

    /// The frame before or after, round from the ends.
    public func stepFrame(by d: Int) {
        let n = frameCount
        showFrame(((frame + d) % n + n) % n)
    }

    /// A new, clear frame after this one, shown.
    public func addFrame() {
        let at = frame + 1
        change(.addFrame(at: UInt32(at)), label: "New frame")
        showFrame(at)
    }

    /// A copy of this frame, after it, shown (⇧N).
    public func copyFrame() {
        let at = frame + 1
        change(.addFrame(at: UInt32(at), copy: UInt32(frame)), label: "Copy the frame")
        showFrame(at)
    }

    /// This frame taken out, and every layer's pixels in it.
    public func removeFrame() {
        guard frameCount > 1 else { return }
        change(.removeFrame(UInt32(frame)), label: "Remove the frame")
    }

    /// A frame moved to another place, shown there.
    public func moveFrame(_ from: Int, to: Int) {
        guard from != to, (0..<frameCount).contains(from), (0..<frameCount).contains(to) else { return }
        change(.moveFrame(UInt32(from), to: UInt32(to)), label: "Move the frame")
        showFrame(to)
    }

    /// How long this frame shows, in milliseconds (1 to 60 000).
    public func setDuration(_ ms: Int) {
        guard (1...60_000).contains(ms), document?.state.frames[safe: frame] != UInt32(ms) else { return }
        change(.setDuration(from: UInt32(frame), to: UInt32(frame), duration: UInt32(ms)), label: "Frame time")
    }

    /// Every frame shown as long as this one.
    public func setDurationForAll() {
        guard let ms = document?.state.frames[safe: frame] else { return }
        change(.setDuration(from: 0, to: UInt32(frameCount - 1), duration: ms), label: "Frame times")
    }

    // MARK: Tags

    /// The tags made so, as one edit.
    public func setTags(_ next: [CanvasTag]) {
        guard next != tags else { return }
        change(.setTags(next), label: "Tags")
    }

    /// A tag over the frame shown, named apart, to widen.
    public func addTag() {
        var k = tags.count + 1
        while tags.contains(where: { $0.name == "Tag \(k)" }) { k += 1 }
        setTags(tags + [CanvasTag(name: "Tag \(k)", from: UInt32(frame), to: UInt32(frame))])
    }

    /// Tag `i` changed: its name, its first and last frames (held in order
    /// and to the frames there are), or how it plays.
    public func editTag(_ i: Int, name: String? = nil, from: Int? = nil, to: Int? = nil, direction: CanvasDirection? = nil) {
        guard tags.indices.contains(i) else { return }
        var next = tags
        var tag = next[i]
        let last = UInt32(frameCount - 1)
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { tag.name = trimmed }
        }
        if let from { tag.from = min(last, UInt32(max(0, from))) }
        if let to { tag.to = min(last, UInt32(max(0, to))) }
        if tag.from > tag.to { (tag.from, tag.to) = from != nil ? (tag.from, tag.from) : (tag.to, tag.to) }
        if let direction { tag.direction = direction }
        next[i] = tag
        setTags(next)
    }

    public func removeTag(_ i: Int) {
        guard tags.indices.contains(i) else { return }
        var next = tags
        let gone = next.remove(at: i)
        if playTag == gone.name { playTag = "" }
        setTags(next)
    }

    // MARK: Playing

    /// Frames playing, each for its time.
    public private(set) var playing = false
    /// The tag playing goes round, by name; "" for every frame.
    public var playTag = "" {
        didSet {
            guard playTag != oldValue else { return }
            if let tag = playingTag, frame < Int(tag.from) || frame > Int(tag.to) { showFrame(Int(tag.from), keepPlaying: true) }
            if playing { play() }
        }
    }
    @ObservationIgnored private var player: Task<Void, Never>?

    /// The tag playing goes round, if it is still there.
    public var playingTag: CanvasTag? { tags.first { $0.name == playTag } }

    /// Play the frames — a tag's, or all — from the one shown, each for its
    /// time, round and round until stopped. Onion skin is off meanwhile.
    public func play() {
        guard document != nil, frameCount > 1 else { return }
        player?.cancel()
        finishTransform()
        let first = CanvasRun(frames: frameCount, tag: playingTag).start(at: frame)
        playing = true
        applyOnion()
        showFrame(first.frame, keepPlaying: true)
        let heading = first.forward
        player = Task { [weak self] in
            var forward = heading
            let clock = ContinuousClock()
            var due = clock.now
            while let self, self.playing, !Task.isCancelled {
                // Fallen far behind — a long frame, a busy Mac — it goes on from now.
                if due < clock.now - .milliseconds(250) { due = clock.now }
                due += .milliseconds(Int(self.document?.state.frames[safe: self.frame] ?? 100))
                try? await clock.sleep(until: due)
                guard self.playing, !Task.isCancelled else { return }
                let next = CanvasRun(frames: self.frameCount, tag: self.playingTag).step(at: self.frame, forward: forward)
                forward = next.forward
                self.showFrame(next.frame, keepPlaying: true)
            }
        }
    }

    public func stop() {
        guard playing else { return }
        player?.cancel()
        player = nil
        playing = false
        applyOnion()
    }

    public func togglePlaying() { playing ? stop() : play() }

    // MARK: Onion skin

    /// Onion skin: the frames either side shown faintly under each layer,
    /// how many each way (0 to 3), tinted red before and blue after. Kept
    /// between launches, as Proton's window kept it.
    public var onionOn = false { didSet { onionChanged() } }
    public var onionBefore = 1 { didSet { onionChanged() } }
    public var onionAfter = 1 { didSet { onionChanged() } }
    public var onionTint = true { didSet { onionChanged() } }

    /// How strongly the nearest frame shows, of 255: Proton's.
    static let onionOpacity = 110
    private static let onionKept = "aether.canvas.onion"

    private func onionChanged() {
        applyOnion()
        defaults.set(["on": onionOn, "before": onionBefore, "after": onionAfter, "tint": onionTint], forKey: Self.onionKept)
    }

    private func loadOnion() {
        guard let kept = defaults.dictionary(forKey: Self.onionKept) else { return }
        let reach = { (v: Any?, d: Int) in (v as? Int).map { min(3, max(0, $0)) } ?? d }
        (onionOn, onionBefore, onionAfter, onionTint) = (kept["on"] as? Bool ?? false, reach(kept["before"], 1), reach(kept["after"], 1), kept["tint"] as? Bool ?? true)
    }

    /// Onion skin as set, to the canvas: none while frames play.
    func applyOnion() {
        let on = onionOn && !playing
        document?.onion(before: on ? onionBefore : 0, after: on ? onionAfter : 0, opacity: Self.onionOpacity, tint: onionTint)
    }

    // MARK: Thumbnails

    /// Each frame small, for the timeline, drawn again as frames change.
    public private(set) var thumbs: [Int: CGImage] = [:]
    /// Device pixels: a 40-point cell on a Retina screen, so every pixel of
    /// a small sprite is in it.
    static let thumbSide = 80

    /// The thumbnails of the frames whose pictures changed, drawn again.
    public func refreshThumbs() {
        guard let document else { return thumbs = [:] }
        let n = frameCount
        let stale = document.takeStaleFrames() ?? Set(0..<n)
        var next = thumbs.filter { $0.key < n }
        for f in stale where f < n {
            next[f] = document.thumbnail(frame: f, side: Self.thumbSide)
        }
        thumbs = next
    }

    // MARK: Colour

    /// Remember `color` as used.
    func used(_ color: RGBA) {
        recent.removeAll { $0 == color }
        recent.insert(color, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
    }

    /// The colour drawn with from a hex code: `#rgb`, `#rrggbb` or
    /// `#rrggbbaa`. Whether it was one.
    @discardableResult
    public func setColor(hex: String) -> Bool {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return false }
        let bytes = s.count == 6 ? [UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255), 255]
            : [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
        color = RGBA(bytes)
        return true
    }

    /// The pencil's tip as it draws: with the mirror lines on, given as
    /// twice their place, so the canvas's width is its middle.
    public var drawingTip: CanvasTip {
        var t = tip
        t.mirror = [mirrorAcross ? document.map { Int32($0.width) } : nil, mirrorDown ? document.map { Int32($0.height) } : nil]
        return t
    }

    // MARK: The palette

    public var palette: [RGBA] { document?.state.palette.map(RGBA.init) ?? [] }

    /// A swatch chosen: the colour drawn with, and what Recolour changes.
    public func chooseSwatch(_ index: Int) {
        guard palette.indices.contains(index) else { return }
        color = palette[index]
        swatch = index
    }

    /// The colour drawn with, added to the palette.
    public func addToPalette() {
        guard document != nil, !palette.contains(color) else { return }
        change(.setPalette(palette + [color]), label: "Add a colour")
        swatch = palette.firstIndex(of: color)
    }

    /// Five steps of the colour drawn with, darker and lighter, the hue
    /// turning as a painter's shading does: those not there already, added.
    public func addRamp() {
        guard document != nil else { return }
        let fresh = CanvasDocument.ramp(of: color).filter { !palette.contains($0) }
        guard !fresh.isEmpty else { return }
        change(.setPalette(palette + fresh), label: "Ramp")
    }

    /// The colour drawn with, taken out of the palette.
    public func removeFromPalette() {
        guard palette.contains(color) else { return }
        change(.setPalette(palette.filter { $0 != color }), label: "Remove a colour")
        swatch = nil
    }

    /// Whether the chosen swatch is a colour other than the one drawn with.
    public var canRecolour: Bool {
        guard let swatch, palette.indices.contains(swatch) else { return false }
        return palette[swatch] != color
    }

    /// The chosen swatch made the colour drawn with, and every pixel of its
    /// colour on layers not locked, as one edit.
    public func recolourSwatch() {
        guard canRecolour, let swatch else { return }
        change(.replaceColor(from: palette[swatch], to: color, swatch: UInt32(swatch)), label: "Recolour")
    }

    // MARK: The view

    /// The canvas fitted in what the panels leave of the stage: whole
    /// pixels on a pixel canvas, once it is at least its size.
    public func fit() {
        guard let document, stageSize.width > 0 else { return }
        let free = freeRect
        let fitted = min(free.width / CGFloat(document.width), free.height / CGFloat(document.height))
        var scale = min(CanvasViewport.most, max(CanvasViewport.least, fitted))
        if document.state.preset == .pixel, scale >= 1 { scale = scale.rounded(.down) }
        viewport.scale = scale
        center(in: free)
    }

    /// One canvas pixel to a point, centred.
    public func actualSize() {
        guard document != nil else { return }
        viewport.scale = 1
        center(in: freeRect)
    }

    public func zoom(by factor: CGFloat) {
        let free = freeRect
        viewport.zoom(by: factor, around: CGPoint(x: free.midX, y: free.midY))
    }

    private func center(in rect: CGRect) {
        guard let document else { return }
        viewport.offset = CGPoint(x: (rect.midX - CGFloat(document.width) * viewport.scale / 2).rounded(),
                                  y: (rect.midY - CGFloat(document.height) * viewport.scale / 2).rounded())
    }

    /// The stage less the panels, the status bar and the dock, and a margin.
    var freeRect: CGRect {
        let left: CGFloat = navigatorOpen ? 264 : 0
        let right: CGFloat = inspectorOpen ? 300 : 0
        // The dock, and the timeline over it.
        let bottom: CGFloat = 84 + CanvasTimeline.height(frames: frameCount) + 10
        return CGRect(x: left + 32, y: 58, width: max(64, stageSize.width - left - right - 64), height: max(64, stageSize.height - 58 - bottom))
    }

    // MARK: Keys

    /// A key pressed with the canvas on screen: a tool, a size, a view.
    /// Answers whether it was used.
    public func handleKey(_ event: NSEvent) -> Bool {
        if NSApplication.shared.keyWindow?.firstResponder is NSTextView { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty, let document, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let pixel = document.state.preset == .pixel
        // ↩ keeps what is being moved, ⎋ leaves it; ⌫ clears what is selected.
        let code = event.keyCode
        if moving != nil, code == 36 || code == 76 {
            finishTransform()
            return true
        }
        if moving != nil, code == 53 {
            leaveTransform()
            return true
        }
        if code == 51 || code == 117 {
            clearSelected()
            return true
        }
        // ↩ plays the frames or stops them; ⎋ stops them too.
        if code == 36 || code == 76 {
            togglePlaying()
            return true
        }
        if playing, code == 53 {
            stop()
            return true
        }
        switch key {
        case " ":
            panning = true
        case "b": tool = pixel ? .pencil : .brush
        case "n":
            if shift { copyFrame() } else { tool = pixel ? .brush : .pencil }
        case "e": tool = .eraser
        case "g":
            if shift { showGrid.toggle() } else { tool = .fill }
        case "m":
            if shift { mirrorDown.toggle() } else { mirrorAcross.toggle() }
        case "i": tool = .pick
        case "l": tool = .line
        case "r": tool = .rect
        case "o":
            if shift { onionOn.toggle() } else { tool = .ellipse }
        case ",", "<": stepFrame(by: -1)
        case ".", ">": stepFrame(by: 1)
        case "s":
            // Again, the next shape: a rectangle, an ellipse, a lasso.
            if tool == .select {
                let all = CanvasSelectShape.allCases
                selectShape = all[(all.firstIndex(of: selectShape)! + 1) % all.count]
            }
            tool = .select
        case "w": tool = .wand
        case "v": tool = .move
        case "[": resize(smaller: true)
        case "]": resize(smaller: false)
        case "p": pixelPerfect.toggle()
        case "f": fit()
        case "1" where !shift: actualSize()
        case "=", "+": zoom(by: 2)
        case "-": zoom(by: 0.5)
        default:
            return false
        }
        return true
    }

    public func handleKeyUp(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " ", panning else { return false }
        panning = false
        return true
    }

    /// The brush (or the tip, drawing pixels) a step smaller or larger.
    func resize(smaller: Bool) {
        if usesTip {
            let next = smaller ? Int(tip.size) - 1 : Int(tip.size) + 1
            tip.size = UInt32(min(64, max(1, next)))
        } else {
            let size = Double(brush.size)
            let next = smaller ? size / 1.25 : size * 1.25
            brush.size = UInt32(min(1000, max(1, smaller ? next.rounded(.down) : max(size + 1, next.rounded()))))
        }
    }

    /// Whether the tool draws with a pencil's tip (and the eraser does on a
    /// pixel canvas) rather than a brush.
    public var usesTip: Bool {
        switch tool {
        case .pencil, .line, .rect, .ellipse: true
        case .eraser: document?.state.preset == .pixel
        default: false
        }
    }

    static func describe(_ error: Error) -> String {
        CanvasDocument.describe(error)
    }
}

/// Pictures from outside — the clipboard, a file dropped — as the core
/// reads them: PNG, Photoshop and Aseprite as they are, anything else
/// macOS can open (a JPEG, a TIFF, a screenshot) made a PNG.
enum CanvasPicture {
    static func readable(_ bytes: Data) -> Data {
        let png = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let psd = bytes.starts(with: Array("8BPS".utf8))
        let aseprite = bytes.count >= 6 && bytes[bytes.startIndex + 4] == 0xE0 && bytes[bytes.startIndex + 5] == 0xA5
        guard !png, !psd, !aseprite, let rep = NSBitmapImageRep(data: bytes), let made = rep.representation(using: .png, properties: [:]) else { return bytes }
        return made
    }

    /// A picture on the clipboard and a name for it: an image file copied
    /// in the Finder, or a picture copied in another app.
    static func on(_ board: NSPasteboard) -> (Data, String)? {
        let kinds: Set<String> = ["png", "jpg", "jpeg", "psd", "aseprite", "ase", "tif", "tiff", "gif", "heic", "webp", "bmp"]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { kinds.contains($0.pathExtension.lowercased()) }), let bytes = try? Data(contentsOf: url) {
            return (bytes, url.lastPathComponent)
        }
        if let png = board.data(forType: .png) { return (png, "Pasted") }
        if let tiff = board.data(forType: .tiff) { return (tiff, "Pasted") }
        return nil
    }
}

/// A canvas's picture, small, for its card: the flat PNG a pixel canvas
/// keeps, or its layers laid one over another.
enum CanvasThumbnail {
    static func make(_ file: CanvasFile, side: Int = 240) -> CGImage? {
        let flat = file.url.appending(path: "flat.png")
        if let image = scaled(flat, side: side) { return image }
        struct Manifest: Decodable {
            struct Entry: Decodable {
                var file: String
                var opacity: Int
                var hidden: Bool
            }
            var layers: [Entry]
        }
        guard let data = try? Data(contentsOf: file.url.appending(path: "canvas.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let ratio = Double(side) / Double(max(file.width, file.height))
        let (w, h) = (max(1, Int(Double(file.width) * ratio)), max(1, Int(Double(file.height) * ratio)))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        for entry in manifest.layers where !entry.hidden {
            guard let image = scaled(file.url.appending(path: entry.file), side: side) else { continue }
            context.setAlpha(CGFloat(entry.opacity) / 255)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return context.makeImage()
    }

    private static func scaled(_ url: URL, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension Array {
    /// The element at `i`, or nil past the ends.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
