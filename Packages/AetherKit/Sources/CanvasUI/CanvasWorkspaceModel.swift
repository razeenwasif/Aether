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

    public let folder: URL

    public init(folder: URL = CanvasWorkspaceModel.defaultFolder) {
        self.folder = folder
        refreshList()
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
    public func receive(_ bytes: Data, named name: String, keep: Bool) {
        leave {
            let stem = (name as NSString).deletingPathExtension
            do {
                let doc = try CanvasDocument.importing(CanvasPicture.readable(bytes), named: name, at: self.unique(stem.isEmpty ? "Picture" : stem))
                if keep { try doc.save() }
                self.show(doc)
                self.refreshList()
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
            refreshList()
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
            try document.save(as: url)
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

    /// Back to the home page.
    public func close() {
        leave {
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
        moving = nil
        document = doc
        layer = doc.state.layers.last?.id
        if doc.state.preset == .pixel, tool == .brush { tool = .pencil }
        if doc.state.preset == .paint, tool == .pencil { tool = .brush }
        if doc.state.preset == .pixel, recent.isEmpty, let first = doc.state.palette.first { color = RGBA(first) }
        fit()
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
        finishTransform()
        if document.apply(op, label: label) == nil { notice = document.refusal }
    }

    /// Undo; while something is being moved, that move is left instead.
    public func undo() {
        if moving != nil { return leaveTransform() }
        document?.undo()
    }

    public func redo() {
        if moving != nil { return leaveTransform() }
        document?.redo()
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
        select(.wand(layer: layer.id, x: Int32(floor(c.x)), y: Int32(floor(c.y)), tolerance: wandTolerance, contiguous: wandContiguous, diagonal: wandDiagonal), mode: mode)
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
        change(.clear(layer: layer.id), label: "Clear")
    }

    // MARK: The clipboard

    /// What is selected of the layer — all of it, with nothing selected —
    /// copied, and put on the system's clipboard as a PNG; cut, cleared too.
    public func copy(cut: Bool = false) {
        guard let document, let layer = currentLayer else { return }
        finishTransform()
        guard document.apply(.copy(layer: layer.id, cut: cut), label: cut ? "Cut" : "Copy") != nil else {
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
        if let made = document.apply(.paste(above: currentLayer?.id), label: "Paste")?.made {
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
        guard let lifted = document.lift(layer.id) else {
            notice = "There’s nothing on \(layer.name) to move."
            return false
        }
        document.preview(.clear(layer: layer.id))
        moving = CanvasMoving(layer: layer.id, rect: lifted.rect, transform: CanvasTransform(lifted.rect), free: free, image: lifted.image)
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

    // MARK: Colour

    /// Remember `color` as used.
    func used(_ color: RGBA) {
        recent.removeAll { $0 == color }
        recent.insert(color, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
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
        return CGRect(x: left + 32, y: 58, width: max(64, stageSize.width - left - right - 64), height: max(64, stageSize.height - 58 - 84))
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
        switch key {
        case " ":
            panning = true
        case "b": tool = pixel ? .pencil : .brush
        case "n": tool = pixel ? .brush : .pencil
        case "e": tool = .eraser
        case "g": tool = .fill
        case "i": tool = .pick
        case "l": tool = .line
        case "r": tool = .rect
        case "o": tool = .ellipse
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
