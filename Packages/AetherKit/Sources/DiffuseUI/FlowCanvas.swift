import AetherDesign
import AppKit
import DiffuseCore
import SwiftUI

/// A wire being drawn: from the port the drag began at to the pointer.
struct PendingWire: Equatable {
    /// The output it comes from, when the drag began at one (or at a linked
    /// input, which lifts its link off).
    var output: FlowPort?
    /// The input it goes into, when the drag began at an unlinked input.
    var input: FlowPort?
    /// A linked input the drag lifted the link from.
    var lifted: FlowPort?
    var socket: String?
    var start: CGPoint
    var end: CGPoint
}

/// The flow, drawn: an infinite dotted ground, wires, and node cards that
/// drag, link and select. Pans with two fingers or the space bar's drag,
/// zooms with a pinch or ⌘-scroll.
struct FlowCanvas: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor

    @State private var pan = CGSize(width: 60, height: 80)
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var dragIDs: Set<String> = []
    @State private var dragBy: CGSize = .zero
    @State private var wire: PendingWire?
    @State private var panStart: CGSize?
    @State private var size: CGSize = .zero
    @State private var hoverLocation: CGPoint?
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool

    private var catalogue: Catalogue { editor.library.catalogue }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ground
                content
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, location in
                let pictures = urls.filter(DiffuseWorkspaceModel.isPicture)
                guard !pictures.isEmpty else { return false }
                let point = toFlow(location)
                // Dropped on a Load Image: its picture.
                let onto = editor.flow.nodes.last { node in
                    guard editor.pictureField(of: node) != nil else { return false }
                    let height = NodeGeometry(node: node, type: catalogue.node(node.type)).bodyHeight
                    return CGRect(origin: node.position, size: CGSize(width: NodeMetrics.width, height: height)).contains(point)
                }
                Task { await model.dropped(pictures, at: point, onto: onto?.id) }
                return true
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    model.pointer = toFlow(location)
                case .ended:
                    hoverLocation = nil
                    model.pointer = nil
                }
            }
            .gesture(magnify)
            .onAppear {
                size = geo.size
                installScrollMonitor()
                fit()
            }
            .onDisappear(perform: removeScrollMonitor)
            .onChange(of: geo.size) { _, new in
                size = new
                publishCentre()
            }
            .onChange(of: model.fitRequest) { fit() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
    }

    // MARK: Layers

    /// The dotted ground. Dragging it pans; a click clears the selection.
    private var ground: some View {
        Canvas { context, canvasSize in
            let spacing = 20 * zoom
            guard spacing >= 6 else { return }
            let dot = max(1, zoom)
            let startX = pan.width.truncatingRemainder(dividingBy: spacing) - spacing
            let startY = pan.height.truncatingRemainder(dividingBy: spacing) - spacing
            var path = Path()
            var y = startY
            while y < canvasSize.height + spacing {
                var x = startX
                while x < canvasSize.width + spacing {
                    path.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(.white.opacity(0.05)))
        }
        .background(Color.obsidian0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if panStart == nil { panStart = pan }
                    pan = CGSize(width: (panStart?.width ?? 0) + value.translation.width,
                                 height: (panStart?.height ?? 0) + value.translation.height)
                }
                .onEnded { _ in
                    panStart = nil
                    publishCentre()
                }
        )
        .onTapGesture {
            focused = true
            editor.selection.removeAll()
        }
    }

    /// Wires under nodes, in flow space.
    private var content: some View {
        let bounds = contentBounds
        return ZStack(alignment: .topLeading) {
            WireLayer(editor: editor, catalogue: catalogue, offsets: offsets, wire: wire, live: model.queue.active, origin: bounds.origin)
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)
                .allowsHitTesting(false)
            ForEach(editor.flow.nodes) { node in
                let offset = offsets[node.id] ?? .zero
                NodeCard(
                    node: node,
                    type: catalogue.node(node.type),
                    editor: editor,
                    model: model,
                    wire: wire,
                    onDrag: { translation in dragNodes(node.id, by: translation) },
                    onDragEnd: { finishDrag() },
                    onPortDrag: { port, isInput, location in drawWire(from: port, isInput: isInput, to: location) },
                    onPortDragEnd: { location in finishWire(at: location) }
                )
                .offset(x: node.position.x + offset.width, y: node.position.y + offset.height)
            }
        }
        .frame(width: max(bounds.maxX, 1), height: max(bounds.maxY, 1), alignment: .topLeading)
        .coordinateSpace(.named("flow"))
    }

    /// How far each node being dragged has moved so far.
    private var offsets: [String: CGSize] {
        dragIDs.reduce(into: [:]) { $0[$1] = dragBy }
    }

    /// Everything a wire might touch, with room around it.
    private var contentBounds: CGRect {
        var rect = CGRect(x: -2000, y: -2000, width: 4000, height: 4000)
        for node in editor.flow.nodes {
            rect = rect.union(CGRect(x: node.position.x - 2000, y: node.position.y - 2000, width: 4000 + NodeMetrics.width, height: 4000))
        }
        return rect
    }

    // MARK: Nodes

    private func dragNodes(_ id: String, by translation: CGSize) {
        if dragIDs.isEmpty {
            if !editor.selection.contains(id) {
                editor.selection = NSEvent.modifierFlags.contains(.shift) ? editor.selection.union([id]) : [id]
            }
            dragIDs = editor.selection
        }
        dragBy = translation
    }

    private func finishDrag() {
        defer {
            dragIDs = []
            dragBy = .zero
        }
        guard dragBy != .zero else { return }
        let ops: [FlowOp] = dragIDs.sorted().compactMap { id in
            guard let node = editor.flow.node(id) else { return nil }
            return .place(id: id, at: CGPoint(x: node.position.x + dragBy.width, y: node.position.y + dragBy.height))
        }
        model.apply(ops)
    }

    // MARK: Wires

    private func drawWire(from port: FlowPort, isInput: Bool, to location: CGPoint) {
        if wire == nil {
            guard let node = editor.flow.node(port.node) else { return }
            let geometry = NodeGeometry(node: node, type: catalogue.node(node.type))
            if isInput {
                if let link = editor.flow.link(into: port.text), let source = link.source, let from = editor.flow.node(source.node) {
                    // Lift the link off this input and carry it from its output.
                    let fromGeometry = NodeGeometry(node: from, type: catalogue.node(from.type))
                    let start = from.position + fromGeometry.outputPoint(source.name)
                    wire = PendingWire(output: source, input: nil, lifted: port, socket: socketType(output: source), start: start, end: location)
                } else {
                    let start = node.position + geometry.inputPoint(port.name)
                    wire = PendingWire(output: nil, input: port, lifted: nil, socket: socketType(input: port), start: start, end: location)
                }
            } else {
                let start = node.position + geometry.outputPoint(port.name)
                wire = PendingWire(output: port, input: nil, lifted: nil, socket: socketType(output: port), start: start, end: location)
            }
        }
        wire?.end = location
    }

    private func finishWire(at location: CGPoint) {
        guard let pending = wire else { return }
        wire = nil
        var ops: [FlowOp] = []
        if let output = pending.output {
            if let target = nearestPort(to: location, inputs: true), target != pending.lifted {
                if let lifted = pending.lifted { ops.append(.disconnect(to: lifted.text)) }
                ops.append(.connect(from: output.text, to: target.text))
            } else if pending.lifted != nil, nearestPort(to: location, inputs: true) == nil, let lifted = pending.lifted {
                ops.append(.disconnect(to: lifted.text))
            }
        } else if let input = pending.input, let source = nearestPort(to: location, inputs: false) {
            ops.append(.connect(from: source.text, to: input.text))
        }
        model.apply(ops)
    }

    /// The port nearest `point` in flow space, within reach.
    private func nearestPort(to point: CGPoint, inputs: Bool) -> FlowPort? {
        var best: (FlowPort, CGFloat)?
        for node in editor.flow.nodes {
            guard let type = catalogue.node(node.type) else { continue }
            let geometry = NodeGeometry(node: node, type: type)
            let names = inputs ? type.sockets.map(\.name) : type.outputs.map(\.name)
            for name in names {
                let p = node.position + (inputs ? geometry.inputPoint(name) : geometry.outputPoint(name))
                let d = hypot(p.x - point.x, p.y - point.y)
                if d <= NodeMetrics.hitRadius * 1.6, d < (best?.1 ?? .infinity) {
                    best = (FlowPort(node: node.id, name: name), d)
                }
            }
        }
        return best?.0
    }

    private func socketType(output port: FlowPort) -> String? {
        editor.flow.node(port.node).flatMap { catalogue.node($0.type) }?.outputs.first { $0.name == port.name }?.type
    }

    private func socketType(input port: FlowPort) -> String? {
        editor.flow.node(port.node).flatMap { catalogue.node($0.type) }?.sockets.first { $0.name == port.name }?.type
    }

    // MARK: Viewport

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomAtGestureStart == nil { zoomAtGestureStart = zoom }
                let anchor = value.startLocation
                setZoom((zoomAtGestureStart ?? 1) * value.magnification, around: anchor)
            }
            .onEnded { _ in
                zoomAtGestureStart = nil
                publishCentre()
            }
    }

    private func setZoom(_ next: CGFloat, around anchor: CGPoint) {
        let clamped = min(max(next, 0.3), 2.5)
        let ratio = clamped / zoom
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * ratio, height: anchor.y - (anchor.y - pan.height) * ratio)
        zoom = clamped
    }

    private func toFlow(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
    }

    private func publishCentre() {
        model.visibleCentre = toFlow(CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// Fit every node in view, at no more than full size.
    private func fit() {
        guard size.width > 0, !editor.flow.nodes.isEmpty else { return }
        var rect = CGRect.null
        for node in editor.flow.nodes {
            let geometry = NodeGeometry(node: node, type: catalogue.node(node.type))
            rect = rect.union(CGRect(origin: node.position, size: CGSize(width: NodeMetrics.width, height: geometry.bodyHeight)))
        }
        // Leave room for the panels that float over the sides.
        let left: CGFloat = model.libraryOpen ? 280 : 40
        let right: CGFloat = model.inspectorOpen ? 320 : 40
        let usable = CGSize(width: max(size.width - left - right, 200), height: max(size.height - 140, 200))
        let next = min(1, min(usable.width / rect.width, usable.height / rect.height))
        zoom = max(0.3, next)
        pan = CGSize(width: left + (usable.width - rect.width * zoom) / 2 - rect.minX * zoom,
                     height: 60 + (usable.height - rect.height * zoom) / 2 - rect.minY * zoom)
        publishCentre()
    }

    /// Two-finger scroll pans; ⌘-scroll or a mouse wheel zooms.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let location = hoverLocation else { return event }
            MainActor.assumeIsolated {
                if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
                    let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
                    setZoom(zoom * factor, around: location)
                } else {
                    pan.width += event.scrollingDeltaX
                    pan.height += event.scrollingDeltaY
                }
                publishCentre()
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

extension CGPoint {
    static func + (point: CGPoint, offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }
}

/// Every link as a curve from output to input, coloured by what it carries,
/// and the wire being drawn.
struct WireLayer: View {
    let editor: FlowEditor
    let catalogue: Catalogue
    let offsets: [String: CGSize]
    let wire: PendingWire?
    let live: RunItem?
    /// Where this layer's frame starts in flow space; drawing is shifted to match.
    let origin: CGPoint

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: -origin.x, y: -origin.y)
            for link in editor.flow.links {
                    guard let source = link.source, let target = link.target,
                          let from = editor.flow.node(source.node), let to = editor.flow.node(target.node)
                    else { continue }
                    let fromType = catalogue.node(from.type)
                    let start = moved(from) + NodeGeometry(node: from, type: fromType).outputPoint(source.name)
                    let end = moved(to) + NodeGeometry(node: to, type: catalogue.node(to.type)).inputPoint(target.name)
                    let socket = fromType?.outputs.first { $0.name == source.name }?.type
                    let dim = from.isBypassed || to.isBypassed
                    var color = SocketStyle.color(socket)
                    if dim { color = color.opacity(0.35) }
                    let running = live?.runningNode == to.id
                    context.stroke(curve(start, end), with: .color(color), style: StrokeStyle(lineWidth: running ? 2.2 : 1.6, lineCap: .round, dash: dim ? [5, 4] : []))
                }
            if let wire {
                let color = SocketStyle.color(wire.socket)
                let (a, b) = wire.input != nil ? (wire.end, wire.start) : (wire.start, wire.end)
                context.stroke(curve(a, b), with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [6, 4]))
            }
        }
        .drawingGroup()
    }

    private func moved(_ node: FlowNode) -> CGPoint {
        let offset = offsets[node.id] ?? .zero
        return CGPoint(x: node.position.x + offset.width, y: node.position.y + offset.height)
    }

    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        let reach = max(40, abs(b.x - a.x) / 2)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + reach, y: a.y), control2: CGPoint(x: b.x - reach, y: b.y))
        return path
    }
}
