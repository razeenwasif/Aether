import AetherDesign
import AppKit
import DesignCore
import SwiftUI

/// The canvas: a page drawn at each of its breakpoints, side by side, as the
/// design board has Desktop and Mobile. Laid out by `DesignLayout` and drawn
/// with AppKit's own drawing, the text measured and drawn the same way. A
/// click chooses the innermost layer under it, a double-click on text types
/// into it; drag the empty canvas or use two fingers to move over it, pinch
/// or ⌘-scroll to zoom, f to see it all.
struct DesignCanvas: NSViewRepresentable {
    let model: DesignWorkspaceModel
    /// What, changed, means the page must be laid out again.
    let revision: Int
    let pageID: String?
    let selection: String?
    let fitRequest: Int
    /// How much of the canvas the panels cover, left and right.
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)

    func makeNSView(context: Context) -> DesignCanvasView {
        let view = DesignCanvasView()
        view.model = model
        return view
    }

    func updateNSView(_ view: DesignCanvasView, context: Context) {
        view.model = model
        view.insets = insets
        view.update(revision: revision, pageID: pageID, selection: selection, fit: fitRequest)
    }
}

/// One breakpoint's artboard: the page laid out at its width, and where it
/// sits on the canvas.
struct DesignBoard {
    var breakpoint: DesignBreakpoint
    var laid: DesignLaidOut
    var origin: CGPoint

    var rect: CGRect { CGRect(origin: origin, size: CGSize(width: laid.width, height: max(laid.height, 1))) }
}

final class DesignCanvasView: NSView {
    weak var model: DesignWorkspaceModel?
    var insets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0)
    private(set) var boards: [DesignBoard] = []
    private var page: DesignPage?
    private var resolver = DesignResolver(tokens: [])
    private var selection: String?
    private var hovered: String?
    private var drawn = (revision: -1, pageID: String?.none, fit: -1)
    private var fitPending = true
    /// The canvas point at the view's middle, and points on screen a
    /// canvas point.
    private var center = CGPoint.zero
    private var zoom: CGFloat = 0.5
    private var panning: CGPoint?

    /// Between two artboards.
    static let gutter: CGFloat = 120

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Artboards")
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        if fitPending { fitAll() }
    }

    func update(revision: Int, pageID: String?, selection: String?, fit: Int) {
        if revision != drawn.revision || pageID != drawn.pageID {
            build()
        }
        if fit != drawn.fit || pageID != drawn.pageID { fitAll() }
        drawn = (revision, pageID, fit)
        if selection != self.selection {
            self.selection = selection
        }
        needsDisplay = true
    }

    /// Each breakpoint laid out, left to right.
    private func build() {
        guard let model, let page = model.page else {
            boards = []
            page = nil
            return
        }
        self.page = page
        resolver = model.resolver
        var x: CGFloat = 0
        boards = page.breakpoints.map { point in
            let laid = DesignLayout.lay(page, width: point.width, resolver: resolver)
            defer { x += point.width + Self.gutter }
            return DesignBoard(breakpoint: point, laid: laid, origin: CGPoint(x: x, y: 0))
        }
    }

    /// Every artboard, in the canvas between the panels.
    private func fitAll() {
        guard let first = boards.first else { return fitPending = true }
        let all = boards.dropFirst().reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: -40, dy: -60)
        let free = CGSize(width: bounds.width - insets.left - insets.right, height: bounds.height - insets.bottom)
        guard free.width > 80, free.height > 80 else { return fitPending = true }
        fitPending = false
        zoom = max(0.05, min(1, free.width / all.width, free.height / all.height))
        // The artboards' middle at the middle of what the panels leave, their
        // tops near the top when they're tall.
        let screenMid = CGPoint(x: insets.left + free.width / 2, y: free.height / 2)
        let top = all.height * zoom > free.height ? all.minY + (free.height / 2) / zoom : all.midY
        center = CGPoint(x: all.midX - (screenMid.x - bounds.width / 2) / zoom, y: top - (screenMid.y - bounds.height / 2) / zoom)
        needsDisplay = true
    }

    // MARK: Points

    private func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.width / 2) / zoom + center.x, y: (p.y - bounds.height / 2) / zoom + center.y)
    }

    private func screenRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - center.x) * zoom + bounds.width / 2, y: (r.minY - center.y) * zoom + bounds.height / 2, width: r.width * zoom, height: r.height * zoom)
    }

    /// The layer at a point on screen.
    func hit(_ p: CGPoint) -> String? {
        let c = canvasPoint(p)
        for board in boards where board.rect.contains(c) {
            return board.laid.hit(CGPoint(x: c.x - board.origin.x, y: c.y - board.origin.y))
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.obsidian0).setFill()
        bounds.fill()
        guard let page, let cg = NSGraphicsContext.current?.cgContext else { return }
        for board in boards {
            let onScreen = screenRect(board.rect)
            guard onScreen.intersects(bounds.insetBy(dx: -40, dy: -40)) else { continue }
            label(board, above: onScreen)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            // A browser's page is white until something says otherwise.
            NSColor.white.setFill()
            onScreen.fill()
            cg.restoreGState()
            cg.saveGState()
            cg.clip(to: onScreen)
            cg.translateBy(x: onScreen.minX, y: onScreen.minY)
            cg.scaleBy(x: zoom, y: zoom)
            if let root = page.layer(page.root) { drawLayer(root, in: board.laid, page: page, cg: cg, seen: []) }
            cg.restoreGState()
            outline(hovered, in: board, width: 1, color: Color.ice.opacity(0.6))
            outline(selection, in: board, width: 1.5, color: Color.ice)
        }
    }

    private func label(_ board: DesignBoard, above rect: CGRect) {
        let text = "\(board.breakpoint.name) · \(Int(board.breakpoint.width))"
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(Color.ink2)])
        string.draw(at: CGPoint(x: rect.minX, y: rect.minY - 20))
    }

    private func outline(_ id: String?, in board: DesignBoard, width: CGFloat, color: Color) {
        guard let id, let frame = board.laid.frames[id] else { return }
        let r = screenRect(frame.offsetBy(dx: board.origin.x, dy: board.origin.y)).insetBy(dx: -width / 2, dy: -width / 2)
        let path = NSBezierPath(rect: r)
        path.lineWidth = width
        NSColor(color).setStroke()
        path.stroke()
    }

    private func drawLayer(_ layer: DesignLayer, in laid: DesignLaidOut, page: DesignPage, cg: CGContext, seen: Set<String>) {
        guard let frame = laid.frames[layer.id], !seen.contains(layer.id) else { return }
        let style = layer.style
        let faded = (style.opacity ?? 1) < 1
        if faded {
            cg.setAlpha(max(0, style.opacity ?? 1))
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setAlpha(1)
        }
        let radius = min(resolver.length(style.radius) ?? 0, min(frame.width, frame.height) / 2)
        if let fill = resolver.color(style.fill) {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        if let stroke = resolver.color(style.stroke) {
            stroke.setStroke()
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        if layer.kind == .text {
            let color = resolver.color(style.color) ?? .black
            let text = DesignText.attributed(layer.text, font: resolver.font(style.font), color: color, align: style.textAlign)
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        for child in layer.children.compactMap(page.layer) {
            drawLayer(child, in: laid, page: page, cg: cg, seen: seen.union([layer.id]))
        }
        if faded { cg.endTransparencyLayer() }
    }

    // MARK: Pointer and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let id = hit(p) else {
            model?.selection = nil
            panning = p
            return
        }
        if event.clickCount >= 2 {
            model?.editText(id)
        } else {
            model?.selection = id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = panning else { return }
        let p = convert(event.locationInWindow, from: nil)
        center.x -= (p.x - from.x) / zoom
        center.y -= (p.y - from.y) / zoom
        panning = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        panning = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let now = hit(convert(event.locationInWindow, from: nil))
        if now != hovered {
            hovered = now
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoomBy(1 + event.scrollingDeltaY * 0.01, at: event)
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            center.x -= event.scrollingDeltaX * k / zoom
            center.y -= event.scrollingDeltaY * k / zoom
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoomBy(1 + event.magnification, at: event)
    }

    /// Zoomed by `factor` about the pointer.
    private func zoomBy(_ factor: CGFloat, at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let before = canvasPoint(p)
        zoom = max(0.05, min(8, zoom * factor))
        let after = canvasPoint(p)
        center.x += before.x - after.x
        center.y += before.y - after.y
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: model.removeSelected() // ⌫, ⌦
        case 53: model.chooseParent() // Esc
        default:
            switch event.charactersIgnoringModifiers {
            case "f": model.fit()
            case "t" where event.modifierFlags.isDisjoint(with: [.command, .control]): model.add(.text)
            case "r" where event.modifierFlags.isDisjoint(with: [.command, .control]): model.add(.rect)
            case "a" where event.modifierFlags.isDisjoint(with: [.command, .control]): model.add(.frame)
            default: super.keyDown(with: event)
            }
        }
    }
}
