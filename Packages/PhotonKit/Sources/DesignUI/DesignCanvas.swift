import PhotonDesign
import AppKit
import DesignCore
import SwiftUI

/// The canvas: a page drawn at each of its breakpoints, side by side, as the
/// design board has Desktop and Mobile — or a component being edited, as
/// written and as each option of its props changes it. Laid out by
/// `DesignLayout` and drawn with AppKit's own drawing, the text measured and
/// drawn the same way. A click chooses the innermost layer under it (on a
/// page, a component's layers are its instance), a double-click on text types
/// into it; drag the empty canvas or use two fingers to move over it, pinch
/// or ⌘-scroll to zoom, f to see it all.
struct DesignCanvas: NSViewRepresentable {
    let model: DesignWorkspaceModel
    /// What, changed, means the page must be laid out again.
    let revision: Int
    let pageID: String?
    let selection: String?
    /// The breakpoint or option being edited, whose artboard's name is lit:
    /// nil, the widest breakpoint or the component as written.
    let editing: String?
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
        view.update(revision: revision, pageID: pageID, selection: selection, editing: editing, fit: fitRequest)
    }
}

/// One artboard: a breakpoint's, the page laid out at its width, or an
/// option's of the component being edited; and where it sits on the canvas.
struct DesignBoard {
    /// The breakpoint's id or the option's key; nil, the widest breakpoint
    /// or the component as written.
    var key: String?
    var name: String
    /// The tree as this artboard has it.
    var page: DesignPage
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
    private var editing: String?
    private var hovered: String?
    /// What an artboard is drawn on before its layers.
    private var ground = NSColor.white
    /// Pictures, read once a revision.
    private var pictures: [String: NSImage] = [:]
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

    func update(revision: Int, pageID: String?, selection: String?, editing: String?, fit: Int) {
        if revision != drawn.revision || pageID != drawn.pageID {
            pictures = [:]
            build()
        }
        self.editing = editing
        if fit != drawn.fit || pageID != drawn.pageID { fitAll() }
        drawn = (revision, pageID, fit)
        if selection != self.selection {
            self.selection = selection
        }
        needsDisplay = true
    }

    /// Each artboard laid out, left to right: a page's breakpoints, its
    /// instances expanded; or a component as written, then as each option
    /// changes it, each as wide as it holds.
    private func build() {
        guard let model, let page = model.page else {
            boards = []
            page = nil
            return
        }
        self.page = page
        resolver = model.resolver
        var x: CGFloat = 0
        let sizes = { [weak model] (src: String) in model?.imageSize(src) }
        let widest = page.widestFirst.first?.id
        var drawn: [(key: String?, name: String, page: DesignPage, width: CGFloat)]
        ground = .white
        if let component = model.component {
            let points = model.componentBreakpoints
            let at = points.first { $0.id == model.componentBreakpoint }
            let pages = model.document?.view.pages.compactMap { model.document?.page($0.id) } ?? []
            let placed = pages.first { $0.layers.contains { $0.component == component.id } } ?? pages.first
            ground = placed.flatMap { resolver.color($0.layer($0.root)?.style.fill) } ?? .white
            let options: [(key: String?, name: String)] = [(nil, "As written")] + component.options.map { ($0.key, $0.name) }
            drawn = options.map { key, name in
                // The components it holds, drawn as they are, at the
                // breakpoint it's seen at.
                let expanded = model.document?.expandedComponent(component.id, option: key) ?? component.asPage(key)
                let here = expanded.with(breakpoints: points).at(model.componentBreakpoint)
                // As wide as it holds; as wide as the breakpoint when its
                // root fills, or holds more.
                let natural = DesignLayout.naturalWidth(of: here, resolver: resolver, images: sizes)
                let fills = here.layer(here.root)?.width == .fill
                let width: CGFloat = at.map { fills ? $0.width : min($0.width, max(120, natural)) } ?? min(1280, max(120, natural))
                return (key, at.map { "\(name) · \($0.name)" } ?? name, here, width)
            }
        } else {
            let expanded = model.pageID.flatMap { model.document?.expanded[$0] } ?? page
            drawn = page.breakpoints.map { point in
                (point.id == widest ? nil : point.id, "\(point.name) · \(Int(point.width))", expanded.at(point.id), point.width)
            }
        }
        boards = drawn.map { board in
            let laid = DesignLayout.lay(board.page, width: board.width, resolver: resolver, images: sizes)
            defer { x += board.width + Self.gutter }
            return DesignBoard(key: board.key, name: board.name, page: board.page, laid: laid, origin: CGPoint(x: x, y: 0))
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
    /// The layer at a point on screen; on a page, a component's layer is its
    /// instance's.
    func hit(_ p: CGPoint) -> String? {
        hitBoard(p)?.layer.map(DesignLayer.owner)
    }

    /// The artboard at a point on screen, and the layer there.
    private func hitBoard(_ p: CGPoint) -> (board: DesignBoard, layer: String?)? {
        let c = canvasPoint(p)
        guard let board = boards.first(where: { $0.rect.contains(c) }) else { return nil }
        return (board, board.laid.hit(CGPoint(x: c.x - board.origin.x, y: c.y - board.origin.y)))
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
            // A browser's page is white until something says otherwise; a
            // component sits on the ground of the page it's placed on.
            ground.setFill()
            onScreen.fill()
            cg.restoreGState()
            cg.saveGState()
            cg.clip(to: onScreen)
            cg.translateBy(x: onScreen.minX, y: onScreen.minY)
            cg.scaleBy(x: zoom, y: zoom)
            let here = board.page
            if let root = here.layer(here.root) { drawLayer(root, in: board.laid, page: here, cg: cg, seen: []) }
            cg.restoreGState()
            outline(hovered, in: board, width: 1, color: Color.ice.opacity(0.6))
            outline(selection, in: board, width: 1.5, color: Color.ice)
        }
    }

    private func label(_ board: DesignBoard, above rect: CGRect) {
        let text = board.name
        let editing = board.key == self.editing
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: editing ? .semibold : .medium), .foregroundColor: NSColor(editing ? Color.ice : Color.ink2)])
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
        guard let frame = laid.frames[layer.id], !seen.contains(layer.id), !layer.hidden else { return }
        let style = layer.style
        let faded = (style.opacity ?? 1) < 1
        if faded {
            // Its own state, so the alpha ends with it rather than fading
            // every layer drawn after.
            cg.saveGState()
            cg.setAlpha(max(0, style.opacity ?? 1))
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setAlpha(1)
        }
        let radius = min(resolver.length(style.radius) ?? 0, min(frame.width, frame.height) / 2)
        if let fill = resolver.color(style.fill) {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        if layer.kind == .image {
            drawPicture(layer, in: frame, radius: radius, cg: cg)
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
        if faded {
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
    }

    /// A picture filling its layer as `fit` says, its corners rounded; a
    /// frame saying so where there's no picture to draw.
    private func drawPicture(_ layer: DesignLayer, in frame: CGRect, radius: CGFloat, cg: CGContext) {
        let image: NSImage? = pictures[layer.src] ?? {
            guard let model, let document = model.document, let read = NSImage(contentsOf: document.file(layer.src)) else { return nil }
            pictures[layer.src] = read
            return read
        }()
        cg.saveGState()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            NSColor(Color.raise2).setFill()
            frame.fill()
            let note = NSAttributedString(string: "No picture at \(layer.src)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(Color.ink2)])
            note.draw(at: CGPoint(x: frame.minX + 8, y: frame.minY + 8))
            cg.restoreGState()
            return
        }
        let scale = layer.style.fit == "contain"
            ? min(frame.width / image.size.width, frame.height / image.size.height)
            : max(frame.width / image.size.width, frame.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        cg.restoreGState()
    }

    // MARK: Pointer and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let found = hitBoard(p)
        // A click on an artboard edits that artboard's breakpoint, or option.
        if let board = found?.board, let model {
            if model.component != nil { model.variant = board.key } else { model.breakpoint = board.key }
        }
        guard let id = found?.layer.map(DesignLayer.owner) else {
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
