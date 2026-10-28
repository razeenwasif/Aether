import AetherDesign
import AppKit
import CanvasCore
import QuartzCore
import SwiftUI

/// The canvas edge to edge: its tiles, zoomed and panned, drawn on with
/// the mouse or a pen.
struct CanvasStage: NSViewRepresentable {
    let model: CanvasWorkspaceModel
    let document: CanvasDocument

    func makeNSView(context: Context) -> CanvasStageView {
        CanvasStageView(model: model, document: document)
    }

    func updateNSView(_ view: CanvasStageView, context: Context) {
        // Read so a change draws again: new pixels, the view, the tool.
        _ = document.drawn
        _ = (model.tool, model.brush.size, model.tip.size, model.panning)
        view.show(model.viewport)
        view.refreshTiles()
        view.toolChanged()
    }
}

/// The canvas's tiles as layers in canvas pixels under one layer that
/// zooms and pans them, over a checkerboard that shows what is clear.
final class CanvasStageView: NSView {
    private let model: CanvasWorkspaceModel
    private let document: CanvasDocument
    private let world = CALayer()
    private let backdrop = CALayer()
    private let outline = CAShapeLayer()
    private var tiles: [Int: CALayer] = [:]
    private var drag: Drag?
    private var tracking: NSTrackingArea?
    private var shown: CanvasViewport?

    private enum Drag {
        case stroke(label: String)
        case shape(CanvasShape, from: CGPoint, filled: Bool)
        case pan(from: CGPoint, offset: CGPoint)
        case pick
    }

    /// No layer here animates: a canvas follows the pen.
    private static let still: [String: CAAction] = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                    "path": NSNull(), "hidden": NSNull(), "frame": NSNull(), "magnificationFilter": NSNull()]

    init(model: CanvasWorkspaceModel, document: CanvasDocument) {
        self.model = model
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Color.obsidian0).cgColor
        backdrop.backgroundColor = Self.checker
        backdrop.shadowColor = NSColor.black.cgColor
        backdrop.shadowOpacity = 0.5
        backdrop.shadowRadius = 18
        backdrop.shadowOffset = CGSize(width: 0, height: 8)
        backdrop.actions = Self.still
        world.anchorPoint = .zero
        world.actions = Self.still
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        outline.lineWidth = 1
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.9
        outline.shadowRadius = 0.5
        outline.shadowOffset = .zero
        outline.actions = Self.still
        outline.isHidden = true
        layer?.addSublayer(backdrop)
        layer?.addSublayer(world)
        layer?.addSublayer(outline)
        buildTiles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard model.stageSize != size else { return }
        DispatchQueue.main.async { [model] in
            let first = model.stageSize == .zero
            model.stageSize = size
            if first { model.fit() }
        }
    }

    // MARK: Drawing

    /// A tile layer for every tile, with what it shows now.
    private func buildTiles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles.values.forEach { $0.removeFromSuperlayer() }
        tiles = [:]
        let pixels = document.pixels
        world.bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        _ = pixels.takeChanged()
        for index in 0..<(pixels.columns * pixels.rows) {
            let tile = CALayer()
            tile.actions = Self.still
            tile.frame = pixels.frame(of: index)
            tile.edgeAntialiasingMask = []
            tile.contents = pixels.image(of: index)
            world.addSublayer(tile)
            tiles[index] = tile
        }
        filter()
        CATransaction.commit()
    }

    /// The tiles the core laid again, shown.
    func refreshTiles() {
        let pixels = document.pixels
        if tiles.count != pixels.columns * pixels.rows || world.bounds.width != CGFloat(pixels.width) || world.bounds.height != CGFloat(pixels.height) {
            return buildTiles()
        }
        let changed = pixels.takeChanged()
        guard !changed.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in changed {
            tiles[index]?.contents = pixels.image(of: index)
        }
        CATransaction.commit()
    }

    /// Pixels stay square on a pixel canvas, and when zoomed in on a
    /// painting; smooth otherwise.
    private func filter() {
        let sharp = document.state.preset == .pixel || model.viewport.scale >= 3
        let mag: CALayerContentsFilter = sharp ? .nearest : .linear
        for tile in tiles.values where tile.magnificationFilter != mag {
            tile.magnificationFilter = mag
            tile.minificationFilter = .linear
        }
    }

    func show(_ viewport: CanvasViewport) {
        guard viewport != shown else { return }
        shown = viewport
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.position = viewport.offset
        world.transform = CATransform3DMakeScale(viewport.scale, viewport.scale, 1)
        backdrop.frame = CGRect(x: viewport.offset.x, y: viewport.offset.y,
                                width: CGFloat(document.width) * viewport.scale, height: CGFloat(document.height) * viewport.scale)
        filter()
        CATransaction.commit()
        if let at = window?.mouseLocationOutsideOfEventStream { place(outlineAt: convert(at, from: nil)) }
    }

    /// The viewport changed here: kept in the model and shown at once.
    private func move(_ change: (inout CanvasViewport) -> Void) {
        var viewport = model.viewport
        change(&viewport)
        model.viewport = viewport
        show(viewport)
    }

    func toolChanged() {
        window?.invalidateCursorRects(for: self)
        if let at = window?.mouseLocationOutsideOfEventStream { place(outlineAt: convert(at, from: nil)) }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        var panning = false
        if case .pan = drag { panning = true }
        addCursorRect(bounds, cursor: model.panning ? (panning ? .closedHand : .openHand) : .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        (model.panning ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        place(outlineAt: p)
        let c = model.viewport.canvasPoint(p)
        let inside = c.x >= 0 && c.y >= 0 && c.x < CGFloat(document.width) && c.y < CGFloat(document.height)
        model.pointer = inside ? CGPoint(x: floor(c.x), y: floor(c.y)) : nil
    }

    override func mouseExited(with event: NSEvent) {
        outline.isHidden = true
        model.pointer = nil
    }

    /// The brush's size under the pointer, or the pencil's square of pixels.
    private func place(outlineAt p: CGPoint) {
        let viewport = model.viewport
        let drawing: Bool = switch model.tool {
        case .brush, .pencil, .eraser: !model.panning
        default: false
        }
        guard drawing, bounds.contains(p) else {
            outline.isHidden = true
            return
        }
        let c = viewport.canvasPoint(p)
        let path: CGPath
        if model.usesTip {
            let n = CGFloat(model.tip.size)
            let corner = CGPoint(x: floor(c.x - (n - 1) / 2), y: floor(c.y - (n - 1) / 2))
            let rect = CGRect(origin: viewport.stagePoint(corner), size: CGSize(width: n * viewport.scale, height: n * viewport.scale))
            guard rect.width >= 4 else { return outline.isHidden = true }
            path = model.tip.round && n > 2 ? CGPath(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil) : CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        } else {
            let d = CGFloat(model.brush.size) * viewport.scale
            guard d >= 4 else { return outline.isHidden = true }
            path = CGPath(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), transform: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = path
        outline.isHidden = false
        CATransaction.commit()
    }

    // MARK: Drawing on it

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        model.viewport.canvasPoint(convert(event.locationInWindow, from: nil))
    }

    /// The pen's pressure, 0 to 1; a mouse presses fully.
    private func pressure(_ event: NSEvent) -> Double {
        event.subtype == .tabletPoint || event.pointingDeviceType == .pen || event.pointingDeviceType == .eraser ? Double(event.pressure) : 1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if model.panning {
            drag = .pan(from: p, offset: model.viewport.offset)
            NSCursor.closedHand.set()
            return
        }
        let c = model.viewport.canvasPoint(p)
        // ⌥ picks a colour with any tool, as in Proton; the pen's eraser
        // end erases.
        let tool: CanvasTool = event.modifierFlags.contains(.option) ? .pick : (event.pointingDeviceType == .eraser ? .eraser : model.tool)
        switch tool {
        case .pick:
            pick(at: c)
            drag = .pick
        case .fill:
            fill(at: c)
        case .brush, .pencil, .eraser:
            beginStroke(tool, at: c, pressure: pressure(event))
        case .line, .rect, .ellipse:
            guard let shape = tool.shape, model.currentLayer != nil else { return }
            let from = CGPoint(x: floor(c.x), y: floor(c.y))
            drag = .shape(shape, from: from, filled: model.shapeFilled && shape != .line)
            previewShape(to: c, shift: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .stroke:
            let c = model.viewport.canvasPoint(p)
            document.addToStroke([(c.x, c.y, pressure(event))])
            refreshTiles()
        case .shape:
            previewShape(to: model.viewport.canvasPoint(p), shift: event.modifierFlags.contains(.shift))
        case let .pan(from, offset):
            move { $0.offset = CGPoint(x: offset.x + p.x - from.x, y: offset.y + p.y - from.y) }
        case .pick:
            pick(at: model.viewport.canvasPoint(p))
        case nil:
            break
        }
        place(outlineAt: p)
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .stroke(let label):
            let c = canvasPoint(event)
            document.addToStroke([(c.x, c.y, pressure(event))])
            document.endStroke(label: label)
        case let .shape(shape, from, filled):
            document.clearPreview()
            if let layer = model.currentLayer {
                let to = constrained(from: from, to: canvasPoint(event), shape: shape, shift: event.modifierFlags.contains(.shift))
                model.change(.shape(layer: layer.id, kind: shape, from: [Int32(from.x), Int32(from.y)], to: [Int32(to.x), Int32(to.y)],
                                    filled: filled, tip: model.tip, color: model.color), label: shape.title)
                model.used(model.color)
            }
        case .pan:
            window?.invalidateCursorRects(for: self)
        case .pick, nil:
            break
        }
        drag = nil
        refreshTiles()
    }

    /// Esc while drawing: the stroke or shape taken away.
    override func cancelOperation(_ sender: Any?) {
        switch drag {
        case .stroke: document.cancelStroke()
        case .shape: document.clearPreview()
        default: break
        }
        drag = nil
        refreshTiles()
    }

    private func beginStroke(_ tool: CanvasTool, at c: CGPoint, pressure: Double) {
        guard let layer = model.currentLayer else { return }
        let erasing = tool == .eraser
        let pixel = document.state.preset == .pixel
        let begin: StrokeBegin
        if tool == .pencil || (erasing && pixel) {
            begin = StrokeBegin(layer: layer.id, tool: erasing ? .eraser : .pencil, tip: model.tip, color: model.color, pixelPerfect: model.pixelPerfect && !erasing)
        } else {
            begin = StrokeBegin(layer: layer.id, tool: erasing ? .eraser : .pencil, brush: model.brush, color: model.color)
        }
        guard document.beginStroke(begin) else {
            model.notice = document.refusal
            return
        }
        if !erasing { model.used(model.color) }
        drag = .stroke(label: tool.title)
        document.addToStroke([(c.x, c.y, pressure)])
        refreshTiles()
    }

    private func fill(at c: CGPoint) {
        guard let layer = model.currentLayer, c.x >= 0, c.y >= 0, c.x < CGFloat(document.width), c.y < CGFloat(document.height) else { return }
        model.change(.fill(layer: layer.id, x: Int32(c.x), y: Int32(c.y), color: model.color, tolerance: model.tolerance, contiguous: model.contiguous), label: "Fill")
        model.used(model.color)
        refreshTiles()
    }

    private func pick(at c: CGPoint) {
        guard let color = document.pick(x: Int(floor(c.x)), y: Int(floor(c.y))), color.a > 0 else { return }
        model.color = color
    }

    private func previewShape(to c: CGPoint, shift: Bool) {
        guard case let .shape(shape, from, filled) = drag, let layer = model.currentLayer else { return }
        let to = constrained(from: from, to: c, shape: shape, shift: shift)
        document.preview(.shape(layer: layer.id, kind: shape, from: [Int32(from.x), Int32(from.y)], to: [Int32(to.x), Int32(to.y)],
                                filled: filled, tip: model.tip, color: model.color))
        refreshTiles()
    }

    /// Where a shape ends: the pixel under the pointer, or with ⇧ a square
    /// (a circle) or a line at a multiple of 45°.
    private func constrained(from: CGPoint, to c: CGPoint, shape: CanvasShape, shift: Bool) -> CGPoint {
        let to = CGPoint(x: floor(c.x), y: floor(c.y))
        guard shift else { return to }
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        if shape == .line {
            // Within 22.5° of level or upright, it is; otherwise diagonal.
            if abs(dx) > 2.414 * abs(dy) { return CGPoint(x: to.x, y: from.y) }
            if abs(dy) > 2.414 * abs(dx) { return CGPoint(x: from.x, y: to.y) }
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: from.x + (dx < 0 ? -side : side), y: from.y + (dy < 0 ? -side : side))
    }

    // MARK: Zoom and pan

    /// Two fingers pan; ⌘ or ⌃ with them, or a wheel with ⌘, zooms.
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            move { $0.zoom(by: exp(dy * 0.01), around: p) }
        } else {
            let k: CGFloat = precise ? 1 : 8
            move { $0.offset = CGPoint(x: $0.offset.x + event.scrollingDeltaX * k, y: $0.offset.y + event.scrollingDeltaY * k) }
        }
        place(outlineAt: p)
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        move { $0.zoom(by: 1 + event.magnification, around: p) }
        place(outlineAt: p)
    }

    override func smartMagnify(with event: NSEvent) {
        model.fit()
    }

    // MARK: The checkerboard

    /// Grey squares, 8 points, under what is clear.
    private static let checker: CGColor = {
        let side = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(white: 0.30, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.22, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: side / 2, height: side / 2).fill()
            NSRect(x: side / 2, y: side / 2, width: side / 2, height: side / 2).fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
    }()
}
