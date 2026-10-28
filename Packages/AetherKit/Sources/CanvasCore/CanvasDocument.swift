import CoreGraphics
import DiffuseBridge
import Foundation
import Observation

/// A canvas open for editing: Proton's `.canvas` folder (its `canvas.json`
/// and a PNG for each layer), edited through the core, one op an undo step.
/// What it shows is read back from the core after each change.
@MainActor
@Observable
public final class CanvasDocument {
    public private(set) var state: CanvasState
    /// The `.canvas` folder: where it was opened from or will be saved.
    public private(set) var url: URL
    /// Why the last change was refused, in the core's words.
    public private(set) var refusal: String?
    /// The pixels laid together, tile by tile, for the view to draw.
    @ObservationIgnored public let pixels: CanvasPixels
    /// Bumped whenever pixels change, so a view knows to draw again.
    public private(set) var drawn = 0
    /// The edges of what is selected, for the marching ants: segments along
    /// pixels' sides, x0, y0, x1, y1 each. Empty when nothing is.
    public private(set) var outline: [Int32] = []
    /// The rectangle round what is selected, in canvas pixels.
    public private(set) var selected: CGRect?
    /// Bumped whenever a frame's picture may have changed, so the timeline
    /// knows to draw its thumbnails again: which ones, `takeStaleFrames`.
    public private(set) var framesDrawn = 0

    @ObservationIgnored let editor: CanvasEditor
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private var selectionVersion = UInt64.max
    /// Frames whose pictures changed since the timeline last asked; all of
    /// them when `staleAll`.
    @ObservationIgnored private var staleFrames: Set<Int> = []
    @ObservationIgnored private var staleAll = true

    private init(editor: CanvasEditor, url: URL) throws {
        self.editor = editor
        self.url = url
        let state = try JSONDecoder().decode(CanvasState.self, from: Data(editor.view().utf8))
        self.state = state
        pixels = CanvasPixels(width: Int(state.width), height: Int(state.height))
        layAll()
        readSelection()
    }

    /// A new canvas, not written until saved.
    public static func create(width: Int, height: Int, preset: CanvasPreset, at url: URL) throws -> CanvasDocument {
        try CanvasDocument(editor: CanvasEditor.create(width: UInt32(width), height: UInt32(height), presetName: preset.rawValue), url: url)
    }

    public static func open(_ url: URL) throws -> CanvasDocument {
        try CanvasDocument(editor: CanvasEditor.open(dir: url.path), url: url)
    }

    /// A new canvas of a picture (a PNG, PSD or Aseprite file), to be saved
    /// at `url`.
    public static func importing(_ bytes: Data, named name: String, at url: URL) throws -> CanvasDocument {
        try CanvasDocument(editor: CanvasEditor.import(bytes: bytes, name: name), url: url)
    }

    /// Its name: the folder's, without `.canvas`.
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var width: Int { Int(state.width) }
    public var height: Int { Int(state.height) }

    // MARK: Changes

    /// Apply `op` as one undo step named `label`; answers the layer it made,
    /// if any, or `nil` with the reason in `refusal` when refused.
    @discardableResult
    public func apply(_ op: CanvasOp, label: String) -> Applied? {
        do {
            let json = String(decoding: try encoder.encode(op), as: UTF8.self)
            let applied = try JSONDecoder().decode(Applied.self, from: Data(editor.apply(opJson: json, label: label).utf8))
            refusal = nil
            refresh()
            stale(applied)
            return applied
        } catch {
            refusal = Self.describe(error)
            return nil
        }
    }

    public func undo() {
        guard let step = editor.undo() else { return }
        refresh()
        stale(try? JSONDecoder().decode(Applied.self, from: Data(step.utf8)))
    }

    public func redo() {
        guard let step = editor.redo() else { return }
        refresh()
        stale(try? JSONDecoder().decode(Applied.self, from: Data(step.utf8)))
    }

    // MARK: Strokes, drawn as the pen moves

    public func beginStroke(_ begin: StrokeBegin) -> Bool {
        do {
            try editor.strokeBegin(beginJson: String(decoding: try encoder.encode(begin), as: UTF8.self))
            refusal = nil
            return true
        } catch {
            refusal = Self.describe(error)
            return false
        }
    }

    /// More of the stroke: x, y in canvas pixels and the pen's pressure, 0 to 1.
    public func addToStroke(_ points: [(x: Double, y: Double, pressure: Double)]) {
        let numbers = points.flatMap { [Int32(($0.x * 256).rounded()), Int32(($0.y * 256).rounded()), Int32((min(1, max(0, $0.pressure)) * 65535).rounded())] }
        guard (try? editor.strokeAdd(points: numbers)) != nil else { return }
        lay()
    }

    public func endStroke(label: String) {
        let ended = try? editor.strokeEnd(label: label)
        refresh()
        stale(ended.flatMap { try? JSONDecoder().decode(Applied.self, from: Data($0.utf8)) })
    }

    public func cancelStroke() {
        editor.strokeCancel()
        lay()
    }

    /// An op shown and not kept: a shape being dragged.
    public func preview(_ op: CanvasOp) {
        guard let json = try? encoder.encode(op) else { return }
        try? editor.preview(opJson: String(decoding: json, as: UTF8.self))
        lay()
    }

    public func clearPreview() {
        editor.previewClear()
        lay()
    }

    /// The colour under a pixel, everything laid together.
    public func pick(x: Int, y: Int) -> RGBA? {
        guard x >= 0, y >= 0 else { return nil }
        return editor.pick(x: UInt32(x), y: UInt32(y)).map { RGBA([UInt8]($0)) }
    }

    // MARK: Files

    /// Write it, into its `.canvas` folder.
    public func save() throws {
        _ = try editor.save(dir: url.path)
        refresh()
    }

    public func save(as newURL: URL) throws {
        _ = try editor.save(dir: newURL.path)
        url = newURL
        refresh()
    }

    /// Everything laid together as a PNG.
    public func png() throws -> Data { try editor.png() }

    // MARK: Selections, moving pixels, the clipboard

    /// What is selected of a layer — all of it, with nothing selected — as
    /// a picture and the rectangle it came from, to be moved. None when
    /// there is nothing there or the layer is locked.
    public func lift(_ layer: UInt32) -> (rect: CGRect, image: CGImage)? {
        guard let lifted = editor.lift(layer: layer),
              let image = CanvasPixels.image(lifted.pixels, width: Int(lifted.width), height: Int(lifted.height)) else { return nil }
        return (CGRect(x: Int(lifted.x), y: Int(lifted.y), width: Int(lifted.width), height: Int(lifted.height)), image)
    }

    /// What was last copied, as a PNG of the part it covers.
    public func clipPNG() -> Data? { editor.clipPng() }

    /// A colour's ramp, darkest first: `steps` colours from `spread` below
    /// its lightness to `spread` above (1/65536), the hue turning by up to
    /// `shift` degrees as a painter's shading does.
    public static func ramp(of base: RGBA, steps: UInt32 = 5, shift: UInt32 = 25, spread: UInt32 = 24000) -> [RGBA] {
        let bytes = [UInt8](canvasRamp(base: Data(base.array), steps: steps, shift: shift, spread: spread))
        return stride(from: 0, to: bytes.count - 3, by: 4).map { RGBA(Array(bytes[$0..<$0 + 4])) }
    }

    /// A picture (PNG, PSD or Aseprite) brought in as layers over `above`,
    /// one undo step. What was left out of it is in the answer's `notes`.
    @discardableResult
    public func bringIn(_ bytes: Data, named name: String, above: UInt32?) -> Applied? {
        do {
            let applied = try JSONDecoder().decode(Applied.self, from: Data(editor.bringIn(bytes: bytes, name: name, above: above).utf8))
            refusal = nil
            refresh()
            stale(applied)
            return applied
        } catch {
            refusal = Self.describe(error)
            return nil
        }
    }

    // MARK: Frames

    /// The frame shown and drawn in, from 0.
    public var frame: Int { Int(state.shown) }

    /// Show frame `frame`, held to the frames there are; a stroke or a
    /// preview under way is taken away first.
    public func show(frame: Int) {
        guard frame != self.frame else { return }
        _ = editor.showFrame(frame: UInt32(max(0, frame)))
        refresh()
    }

    /// Onion skin: how many frames before and after (to 5), how strongly
    /// the nearest shows (of 255), tinted red before and blue after or not.
    public func onion(before: Int, after: Int, opacity: Int = 110, tint: Bool) {
        editor.onion(before: UInt32(max(0, before)), after: UInt32(max(0, after)), opacity: UInt32(max(0, opacity)), tint: tint)
        lay()
    }

    /// Frame `frame` laid together, small: fitted in a square `side` a side.
    public func thumbnail(frame: Int, side: Int) -> CGImage? {
        let (w, h) = CanvasRun.thumbSize(width, height, most: side)
        return CanvasPixels.image(editor.thumb(frame: UInt32(frame), width: UInt32(w), height: UInt32(h)), width: w, height: h)
    }

    /// The frames whose pictures changed since last asked — or `nil` for
    /// every frame — and forget them.
    public func takeStaleFrames() -> Set<Int>? {
        defer {
            staleFrames = []
            staleAll = false
        }
        return staleAll ? nil : staleFrames
    }

    /// What a change touched, as the frames whose thumbnails are stale.
    private func stale(_ applied: Applied?) {
        guard let applied else { return }
        if applied.meta {
            staleAll = true
        } else {
            let frames = (applied.touched ?? []).compactMap { $0.first }.filter { $0 != 0 }.map(CanvasCel.frame(of:))
            guard !frames.isEmpty else { return }
            staleFrames.formUnion(frames)
        }
        framesDrawn &+= 1
    }

    // MARK: Reading back

    /// What the core says the canvas is now, and its pixels laid again.
    private func refresh() {
        if let fresh = try? JSONDecoder().decode(CanvasState.self, from: Data(editor.view().utf8)) {
            if fresh.width != state.width || fresh.height != state.height {
                pixels.resize(width: Int(fresh.width), height: Int(fresh.height))
            }
            state = fresh
        }
        readSelection()
        lay()
    }

    /// The selection's edges again, when the core says they may have moved.
    private func readSelection() {
        let version = editor.selectionVersion()
        guard version != selectionVersion else { return }
        selectionVersion = version
        outline = editor.outline()
        selected = editor.selected().map { CGRect(x: Int($0[0]), y: Int($0[1]), width: Int($0[2]), height: Int($0[3])) }
    }

    /// Lay together what changed and hand it to the pixels.
    public func lay(budget: UInt64 = .max) {
        let parts = editor.lay(budget: budget)
        guard !parts.isEmpty else { return }
        pixels.take(parts)
        drawn &+= 1
    }

    public func layAll() {
        editor.relayAll()
        lay()
    }

    public var pending: Int { Int(editor.pending()) }

    /// What an op changed, as the core says it.
    public struct Applied: Decodable, Sendable {
        public var changed: Bool?
        public var meta: Bool
        /// The tiles it touched, as cel and tile index.
        public var touched: [[UInt32]]?
        public var made: UInt32?
        /// What a picture brought in left out.
        public var notes: [String]?
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? DiffuseError {
            switch e {
            case .Failed(let message), .Gateway(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
