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

    @ObservationIgnored let editor: CanvasEditor
    @ObservationIgnored private let encoder = JSONEncoder()

    private init(editor: CanvasEditor, url: URL) throws {
        self.editor = editor
        self.url = url
        let state = try JSONDecoder().decode(CanvasState.self, from: Data(editor.view().utf8))
        self.state = state
        pixels = CanvasPixels(width: Int(state.width), height: Int(state.height))
        layAll()
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
            return applied
        } catch {
            refusal = Self.describe(error)
            return nil
        }
    }

    public func undo() {
        if editor.undo() != nil { refresh() }
    }

    public func redo() {
        if editor.redo() != nil { refresh() }
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
        _ = try? editor.strokeEnd(label: label)
        refresh()
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

    // MARK: Reading back

    /// What the core says the canvas is now, and its pixels laid again.
    private func refresh() {
        if let fresh = try? JSONDecoder().decode(CanvasState.self, from: Data(editor.view().utf8)) {
            if fresh.width != state.width || fresh.height != state.height {
                pixels.resize(width: Int(fresh.width), height: Int(fresh.height))
            }
            state = fresh
        }
        lay()
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
        public var changed: Bool
        public var meta: Bool
        public var made: UInt32?
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
