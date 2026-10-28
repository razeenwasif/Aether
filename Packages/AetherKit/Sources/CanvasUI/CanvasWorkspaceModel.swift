import AppKit
import CanvasCore
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the pointer does on the canvas.
public enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case brush, pencil, eraser, fill, pick, line, rect, ellipse

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
    public var tool: CanvasTool = .brush
    public var color = RGBA(24, 24, 28)
    /// Colours used lately, newest first.
    public private(set) var recent: [RGBA] = []
    public var brush = CanvasBrush()
    public var tip = CanvasTip(size: 1)
    public var pixelPerfect = true
    public var shapeFilled = false
    public var tolerance: UInt8 = 0
    public var contiguous = true
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
                let doc = try CanvasDocument.importing(bytes, named: name, at: self.unique(stem.isEmpty ? "Picture" : stem))
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
        do {
            try document.save()
            refreshList()
        } catch {
            notice = "Couldn’t save \(document.name): \(Self.describe(error))"
        }
    }

    public func saveAs() {
        guard let document else { return }
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

    /// Apply a change, saying why when it is refused.
    public func change(_ op: CanvasOp, label: String) {
        guard let document else { return }
        if document.apply(op, label: label) == nil { notice = document.refusal }
    }

    public func undo() { document?.undo() }
    public func redo() { document?.redo() }

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
