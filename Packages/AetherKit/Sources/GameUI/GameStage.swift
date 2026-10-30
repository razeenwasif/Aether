import AppKit
import CoreImage
import GameCore
import QuartzCore
import SwiftUI

/// The stage: a room drawn as the game's camera sees it, by the renderer on
/// Metal (`GameRenderer`), lit by the room's lights; what's drawn over it
/// while editing is layers.
///
/// Editing, the camera is the editor's own (pan with two fingers or a drag
/// on nothing, zoom with a pinch or ⌘-scroll), and the planes are placed as
/// the game camera would place them standing at the middle of the stage —
/// Proton's window did the same. Over the play plane: collision by kind, the
/// things in the room, its lights and its spawns, each chosen with a click
/// and moved with a drag. The draw tool makes a line a click a point; a
/// chosen line's points are dragged, ⌥-click puts one in, a double-click
/// takes one out.
///
/// Playing, the run's frame decides it all: the camera follows the
/// player, what the run draws stands on the play plane (an animation by the
/// frame the run is at), the game's finish is laid over it, and the
/// overlays are gone. Ticks run on a fixed clock off the display link, and
/// what is drawn between two ticks is eased between them.
struct GameStage: NSViewRepresentable {
    let model: GameWorkspaceModel
    /// What, changed, means the room must be laid out again.
    let revision: Int
    let roomID: String?
    let selection: GameSelection?
    let playing: Bool
    let fitRequest: Int
    /// How much of the stage the panels cover, left and right: a room is
    /// fitted into what's left.
    let insets: (left: CGFloat, right: CGFloat)
    let tool: GameTool
    /// Whether the editor shows the game's finish.
    let finish: Bool

    func makeNSView(context: Context) -> GameStageView {
        let view = GameStageView()
        view.model = model
        return view
    }

    func updateNSView(_ view: GameStageView, context: Context) {
        view.model = model
        view.insets = insets
        view.tool = tool
        view.finish = finish
        view.update(revision: revision, roomID: roomID, selection: selection, playing: playing, fit: fitRequest)
    }
}

/// What a click on the stage lands on.
enum GameHit: Equatable {
    case entity(String)
    case light(String)
    case spawn(String)
    /// A point of the chosen line.
    case point(String, Int)
    /// A line, near its segment from point `index`.
    case line(String, Int)

    var selection: GameSelection {
        switch self {
        case let .entity(id): .entity(id)
        case let .light(id): .light(id)
        case let .spawn(id): .spawn(id)
        case let .point(id, _), let .line(id, _): .shape(id)
        }
    }
}

final class GameStageView: NSView {
    weak var model: GameWorkspaceModel?
    var insets: (left: CGFloat, right: CGFloat) = (0, 0)
    var tool: GameTool = .select {
        didSet { if tool != oldValue { draft = []; drawDraft(); window?.invalidateCursorRects(for: self) } }
    }
    /// Whether the editor shows the game's finish, as Play does.
    var finish = false {
        didSet { if finish != oldValue { render() } }
    }

    /// The editor's camera: the room point at the stage's middle, and stage
    /// points a room pixel.
    private var center = CGPoint(x: 960, y: 540)
    private var zoom: CGFloat = 0.3
    private var shown: (revision: Int, room: String?, selection: GameSelection?, playing: Bool, fit: Int)?
    /// A fit asked for before the stage had a size: made once it has one.
    private var fitPending = false

    private let root = CALayer()
    /// The room as the renderer draws it: the whole stage while editing, the
    /// game's view, letterboxed, in Play.
    private let metal = CAMetalLayer()
    private let renderer = GameRenderer()
    /// What's drawn over the room while editing, in room pixels: scaled and
    /// moved as the camera says. Its layers by what they mark, to move with
    /// a drag.
    private let scene = CALayer()
    private let overlay = CALayer()
    private var lines: [CAShapeLayer] = []
    private var marks: [String: [CALayer]] = [:]
    /// The line being drawn, and where the pointer is.
    private var draft: [CGPoint] = []
    private var pointer: CGPoint?
    private let draftLayer = CAShapeLayer()
    /// A door's fade, over the game's view.
    private let fade = CALayer()
    private var drawnRoom: GameRoom?
    /// The room as a drag would leave it, drawn while the drag lasts.
    private var previewRoom: GameRoom?
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var playRoom = -1
    private var drag: (start: CGPoint, hit: GameHit?, moved: Bool)?
    private var tracking: NSTrackingArea?

    private static let background = NSColor(calibratedRed: 0.028, green: 0.031, blue: 0.04, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.backgroundColor = Self.background.cgColor
        root.isGeometryFlipped = true
        root.masksToBounds = true
        metal.device = renderer?.device
        metal.pixelFormat = GameRenderer.targetFormat
        metal.framebufferOnly = true
        metal.isOpaque = true
        metal.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        root.addSublayer(metal)
        scene.anchorPoint = .zero
        root.addSublayer(scene)
        draftLayer.fillColor = nil
        draftLayer.lineDashPattern = [12, 8]
        fade.backgroundColor = NSColor.black.cgColor
        fade.opacity = 0
        root.addSublayer(fade)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if model?.playing == true { drawPlay(alpha: 1) } else if fitPending { fitRoom() } else { place() }
    }

    func update(revision: Int, roomID: String?, selection: GameSelection?, playing: Bool, fit: Int) {
        let was = shown
        shown = (revision, roomID, selection, playing, fit)
        if playing != was?.playing {
            playing ? startPlay() : stopPlay()
        }
        if !playing, was?.revision != revision || was?.room != roomID || was?.selection != selection || was?.playing != playing {
            build(room: model?.room)
        }
        if !playing, was?.fit != fit || was?.room != roomID { fitRoom() }
    }

    // MARK: Building

    private var focal: Double { model?.document?.view.game.view.focal ?? 1000 }
    private var gameView: CGSize {
        let v = model?.document?.view.game.view ?? GameViewSettings()
        return CGSize(width: v.width, height: v.height)
    }
    private var pixelArt: Bool { model?.document?.view.game.view.pixelArt == true }
    private var editing: Bool { model?.playing != true }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The room taken in: what's drawn over it made again, editing, and the
    /// room drawn.
    private func build(room: GameRoom?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scene.sublayers?.forEach { $0.removeFromSuperlayer() }
        lines = []
        marks = [:]
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        drawnRoom = room
        previewRoom = nil
        guard let room else { return render() }
        if editing {
            scene.addSublayer(overlay)
            scene.addSublayer(draftLayer)
            buildOverlay(room)
        }
        place()
    }

    // MARK: Drawing the room

    /// The things standing in the room as the editor shows them: each
    /// prefab's image, or its animation's resting frame, on its feet.
    private func resting(_ room: GameRoom) -> [GameStanding] {
        guard let doc = model?.document else { return [] }
        return room.entities.compactMap { entity in
            guard let at = entity.at, at.count == 2, let prefab = doc.view.prefab(entity.prefab), !prefab.sprite.isEmpty else { return nil }
            let frame = prefab.animated ? model?.images.anim(prefab.sprite)?.restingFrame(prefab.clips) : nil
            return GameStanding(key: prefab.sprite, at: CGPoint(x: at[0], y: at[1]), pivot: Self.point(prefab.pivot), frame: frame)
        }
    }

    /// Where a thing standing in the room is drawn, while editing.
    private func restingFrame(_ entity: GameEntity) -> CGRect? {
        guard let at = entity.at, at.count == 2, let prefab = model?.document?.view.prefab(entity.prefab), let images = model?.images else { return nil }
        let frame = prefab.animated ? images.anim(prefab.sprite)?.restingFrame(prefab.clips) : nil
        let standing = GameStanding(key: prefab.sprite, at: CGPoint(x: at[0], y: at[1]), pivot: Self.point(prefab.pivot), frame: frame)
        return GameScene.sprite(standing, art: images.art)?.rect
    }

    /// The room drawn for the editor's camera: the planes as the game camera
    /// would show them from the stage's middle, lit, and finished when asked.
    private func render() {
        guard editing, let renderer, let model else { return }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width >= 1, size.height >= 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        metal.contentsScale = scale
        metal.drawableSize = size
        CATransaction.commit()
        guard let drawable = metal.nextDrawable() else { return }
        var job = GameRenderer.Job(sprites: [], camera: GameCamera(center: center, zoom: zoom * scale), pixelArt: pixelArt)
        if let room = previewRoom ?? drawnRoom {
            job.sprites = GameScene.layout(room, focal: focal, view: gameView, center: center, art: model.images.art, standing: resting(room))
            job.lighting = GameScene.lighting(room, focal: focal, view: gameView, center: center)
            if finish { job.post = model.document?.view.game.post }
        }
        // With the transaction, so the room and the marks over it move as one.
        metal.presentsWithTransaction = true
        renderer.draw(job, images: model.images, into: drawable, presentsWithTransaction: true)
    }

    private static let colours: [String: NSColor] = [
        "solid": NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 0.95),
        "oneway": NSColor(calibratedRed: 0.5, green: 0.95, blue: 0.6, alpha: 0.95),
        "hazard": NSColor(calibratedRed: 1, green: 0.4, blue: 0.4, alpha: 0.95),
        "nowall": NSColor(calibratedRed: 1, green: 0.8, blue: 0.4, alpha: 0.95),
    ]
    private let ice = NSColor(calibratedRed: 0.6, green: 0.78, blue: 1, alpha: 1)

    private func mark(_ key: String, _ layer: CALayer) {
        overlay.addSublayer(layer)
        marks[key, default: []].append(layer)
    }

    /// Collision by kind, the things in the room, its lights and spawns,
    /// what's chosen picked out.
    private func buildOverlay(_ room: GameRoom) {
        let chosen = model?.selection
        for shape in room.collision where shape.points.count >= 2 {
            let selected = chosen == .shape(shape.id)
            let line = CAShapeLayer()
            line.path = Self.path(shape.points.map(Self.point), closed: shape.closed)
            line.fillColor = nil
            line.strokeColor = (Self.colours[shape.kind] ?? Self.colours["solid"]!).cgColor
            if shape.kind == "oneway" { line.lineDashPattern = [10, 6] }
            line.setValue(selected ? 4.0 : 2.0, forKey: "aeWidth")
            mark("shape:\(shape.id)", line)
            lines.append(line)
            if selected {
                // Its points, to drag.
                for p in shape.points.map(Self.point) {
                    let handle = CAShapeLayer()
                    handle.setValue(true, forKey: "aeHandle")
                    handle.position = p
                    handle.fillColor = NSColor.white.cgColor
                    handle.strokeColor = ice.cgColor
                    mark("shape:\(shape.id)", handle)
                    lines.append(handle)
                }
            }
        }
        for entity in room.entities {
            let selected = chosen == .entity(entity.id)
            let key = "entity:\(entity.id)"
            if let r = entity.rect, r.count == 4 {
                let box = CAShapeLayer()
                box.path = CGPath(rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), transform: nil)
                box.fillColor = ice.withAlphaComponent(selected ? 0.22 : 0.08).cgColor
                box.strokeColor = ice.withAlphaComponent(selected ? 1 : 0.6).cgColor
                box.lineDashPattern = selected ? nil : [8, 6]
                box.setValue(2.0, forKey: "aeWidth")
                mark(key, box)
                lines.append(box)
                mark(key, label(entity.id, at: CGPoint(x: r[0], y: r[1] - 30), chosen: selected))
            } else if let at = entity.at, at.count == 2 {
                let ring = CAShapeLayer()
                let radius: CGFloat = 18
                ring.path = CGPath(ellipseIn: CGRect(x: CGFloat(at[0]) - radius, y: CGFloat(at[1]) - radius, width: radius * 2, height: radius * 2), transform: nil)
                ring.fillColor = ice.withAlphaComponent(selected ? 0.35 : 0.12).cgColor
                ring.strokeColor = ice.withAlphaComponent(selected ? 1 : 0.7).cgColor
                ring.setValue(2.0, forKey: "aeWidth")
                mark(key, ring)
                lines.append(ring)
                mark(key, label(entity.id, at: CGPoint(x: at[0] - 40, y: at[1] + 22), chosen: selected))
            }
        }
        for light in room.lights where light.at.count == 2 {
            let selected = chosen == .light(light.id)
            let key = "light:\(light.id)"
            let p = CGPoint(x: light.at[0], y: light.at[1])
            let (r, g, b) = GameScene.rgb(light.color)
            let reach = CAShapeLayer()
            reach.path = CGPath(ellipseIn: CGRect(x: p.x - CGFloat(light.radius), y: p.y - CGFloat(light.radius), width: CGFloat(light.radius * 2), height: CGFloat(light.radius * 2)), transform: nil)
            reach.fillColor = nil
            reach.strokeColor = CGColor(red: r, green: g, blue: b, alpha: selected ? 0.9 : 0.45)
            reach.lineDashPattern = [6, 8]
            reach.setValue(selected ? 3.0 : 1.5, forKey: "aeWidth")
            mark(key, reach)
            lines.append(reach)
            let bulb = CAShapeLayer()
            bulb.path = CGPath(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), transform: nil)
            bulb.fillColor = CGColor(red: r, green: g, blue: b, alpha: 0.9)
            bulb.strokeColor = NSColor.white.withAlphaComponent(selected ? 1 : 0.5).cgColor
            bulb.setValue(2.0, forKey: "aeWidth")
            mark(key, bulb)
            lines.append(bulb)
            mark(key, label(light.id, at: CGPoint(x: p.x + 22, y: p.y - 14), chosen: selected))
        }
        for spawn in room.spawns where spawn.at.count == 2 {
            let selected = chosen == .spawn(spawn.id)
            let key = "spawn:\(spawn.id)"
            let p = CGPoint(x: spawn.at[0], y: spawn.at[1])
            let flag = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p.x - 14, y: p.y))
            path.addLine(to: CGPoint(x: p.x + 14, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - 28))
            path.addLine(to: CGPoint(x: p.x, y: p.y))
            flag.path = path
            flag.strokeColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.45, alpha: selected ? 1 : 0.9).cgColor
            flag.setValue(selected ? 4.0 : 2.0, forKey: "aeWidth")
            mark(key, flag)
            lines.append(flag)
            mark(key, label("spawn \(spawn.id)", at: CGPoint(x: p.x + 8, y: p.y - 40), chosen: selected))
        }
    }

    private func label(_ text: String, at: CGPoint, chosen: Bool) -> CATextLayer {
        let label = CATextLayer()
        label.string = text
        label.fontSize = 22
        label.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        label.foregroundColor = NSColor.white.withAlphaComponent(chosen ? 1 : 0.75).cgColor
        label.contentsScale = 4
        label.frame = CGRect(x: at.x, y: at.y, width: 420, height: 28)
        return label
    }

    private static func point(_ p: [Int]) -> CGPoint { CGPoint(x: p.first ?? 0, y: p.count > 1 ? p[1] : 0) }

    private static func path(_ points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        if closed { path.closeSubpath() }
        return path
    }

    /// The line being drawn: its points, and on to the pointer.
    private func drawDraft() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !draft.isEmpty else { draftLayer.path = nil; return }
        draftLayer.path = Self.path(draft + (pointer.map { [$0] } ?? []), closed: false)
        draftLayer.strokeColor = (Self.colours[model?.drawKind ?? "solid"] ?? Self.colours["solid"]!).cgColor
        draftLayer.lineWidth = 3 / zoom
    }

    // MARK: Placing

    /// The editor's camera applied: the marks scaled and moved, kept the
    /// same size on screen, and the room drawn for it.
    private func place() {
        guard drawnRoom != nil else { return render() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        scene.position = CGPoint(x: bounds.width / 2 - center.x * zoom, y: bounds.height / 2 - center.y * zoom)
        for line in lines {
            if line.value(forKey: "aeHandle") != nil {
                let r = 6 / zoom
                line.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
                line.lineWidth = 1.5 / zoom
            } else {
                line.lineWidth = CGFloat((line.value(forKey: "aeWidth") as? Double) ?? 2) / zoom
            }
        }
        draftLayer.lineWidth = 3 / zoom
        render()
        CATransaction.commit()
    }

    /// The whole room, in the stage between the panels.
    private func fitRoom() {
        guard let room = drawnRoom ?? model?.room else { return }
        let free = bounds.width - insets.left - insets.right
        guard free > 48, bounds.height > 48 else { return fitPending = true }
        fitPending = false
        zoom = max(0.02, min((free - 48) / room.width, (bounds.height - 48) / room.height))
        // The room's middle at the middle of what the panels leave.
        center = CGPoint(x: room.width / 2 - (insets.left - insets.right) / 2 / zoom, y: room.height / 2)
        place()
    }

    /// A point on the stage, in the play plane's room pixels.
    private func roomPoint(_ event: NSEvent) -> CGPoint {
        roomPoint(convert(event.locationInWindow, from: nil))
    }

    private func roomPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.width / 2) / zoom + center.x, y: (p.y - bounds.height / 2) / zoom + center.y)
    }

    // MARK: Editing by hand

    /// What a click at `p` lands on: the chosen line's points first, then
    /// things, lights and spawns, then lines, which run under everything.
    func hit(_ p: CGPoint) -> GameHit? {
        guard let room = drawnRoom else { return nil }
        let reach = 10 / zoom
        if case let .shape(id) = model?.selection, let line = room.shape(id) {
            for (i, q) in line.points.map(Self.point).enumerated() where hypot(p.x - q.x, p.y - q.y) <= reach { return .point(id, i) }
        }
        for entity in room.entities.reversed() {
            if let at = entity.at, at.count == 2 {
                let feet = CGPoint(x: at[0], y: at[1])
                if let frame = restingFrame(entity), frame.contains(p) { return .entity(entity.id) }
                if hypot(p.x - feet.x, p.y - feet.y) <= max(reach * 2, 18) { return .entity(entity.id) }
            } else if let r = entity.rect, r.count == 4, CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -reach, dy: -reach).contains(p) {
                return .entity(entity.id)
            }
        }
        for light in room.lights.reversed() where light.at.count == 2 && hypot(p.x - CGFloat(light.at[0]), p.y - CGFloat(light.at[1])) <= max(reach * 2, 20) {
            return .light(light.id)
        }
        for spawn in room.spawns.reversed() where spawn.at.count == 2 {
            if CGRect(x: spawn.at[0] - 16, y: spawn.at[1] - 32, width: 32, height: 36).insetBy(dx: -reach, dy: -reach).contains(p) { return .spawn(spawn.id) }
        }
        var best: (Double, GameHit)?
        for line in room.collision {
            let points = line.points.map(Self.point)
            let pairs = zip(points, points.dropFirst()).map { ($0, $1) } + (line.closed && points.count > 2 ? [(points[points.count - 1], points[0])] : [])
            for (i, (a, b)) in pairs.enumerated() {
                let d = GameScene.distance(p, toSegment: a, b)
                if d <= reach, d < (best?.0 ?? .infinity) { best = (d, .line(line.id, i)) }
            }
        }
        return best?.1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, editing else { return }
        let p = roomPoint(event)
        switch tool {
        case .draw:
            if event.clickCount >= 2 {
                finishDraft()
            } else {
                draft.append(p)
                drawDraft()
            }
            return
        case .light:
            model.addLight(at: p)
            model.tool = .select
            return
        case let .place(prefab):
            model.place(prefab, at: p)
            model.tool = .select
            return
        case .select:
            break
        }
        let found = hit(p)
        // On the chosen line: ⌥-click puts a point in, a double-click on a
        // point takes it out.
        if case let .shape(id) = model.selection {
            if event.modifierFlags.contains(.option), let line = drawnRoom?.shape(id) {
                let points = line.points.map(Self.point)
                let pairs = zip(points, points.dropFirst()).enumerated().map { ($0, GameScene.distance(p, toSegment: $1.0, $1.1)) }
                if let nearest = pairs.min(by: { $0.1 < $1.1 }) { model.insertPoint(id, at: nearest.0 + 1, p) }
                return
            }
            if event.clickCount >= 2, case let .point(_, index) = found {
                model.removePoint(id, index)
                return
            }
        }
        model.selection = found?.selection
        drag = (p, found, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, editing else { return }
        let p = roomPoint(event)
        if let hit = d.hit {
            // What's dragged follows the pointer; the step is made on release.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview(hit, dx: p.x - d.start.x, dy: p.y - d.start.y, at: p)
            CATransaction.commit()
            d.moved = true
            drag = d
        } else {
            // Nothing under it: the room moves.
            center.x -= event.deltaX / zoom
            center.y -= event.deltaY / zoom
            place()
        }
    }

    /// While something is dragged, its marks move with it; a point drags
    /// its line's path.
    private func preview(_ hit: GameHit, dx: CGFloat, dy: CGFloat, at p: CGPoint) {
        switch hit {
        case let .point(id, index):
            guard let line = drawnRoom?.shape(id) else { return }
            var points = line.points.map(Self.point)
            guard index < points.count else { return }
            points[index] = p
            for layer in marks["shape:\(id)"] ?? [] {
                guard let shapeLayer = layer as? CAShapeLayer else { continue }
                if shapeLayer.value(forKey: "aeHandle") != nil {
                    if hypot(shapeLayer.position.x - line.points.map(Self.point)[index].x, shapeLayer.position.y - line.points.map(Self.point)[index].y) < 0.5 {
                        shapeLayer.setAffineTransform(CGAffineTransform(translationX: dx, y: dy))
                    }
                } else {
                    shapeLayer.path = Self.path(points, closed: line.closed)
                }
            }
        default:
            let key = switch hit.selection {
            case let .entity(id): "entity:\(id)"
            case let .shape(id): "shape:\(id)"
            case let .light(id): "light:\(id)"
            case let .spawn(id): "spawn:\(id)"
            }
            for layer in marks[key] ?? [] { layer.setAffineTransform(CGAffineTransform(translationX: dx, y: dy)) }
        }
        // The room drawn as the drag would leave it: a light's light moves
        // with it, a thing's art with the thing.
        if let room = drawnRoom {
            previewRoom = Self.moved(room, hit, dx: Int(dx.rounded()), dy: Int(dy.rounded()), to: p)
            render()
        }
    }

    /// A room with what a drag holds moved.
    private static func moved(_ room: GameRoom, _ hit: GameHit, dx: Int, dy: Int, to p: CGPoint) -> GameRoom {
        var room = room
        func shifted(_ xy: [Int]) -> [Int] { xy.count >= 2 ? [xy[0] + dx, xy[1] + dy] + xy.dropFirst(2) : xy }
        switch hit {
        case let .entity(id):
            if let i = room.entities.firstIndex(where: { $0.id == id }) {
                room.entities[i].at = room.entities[i].at.map(shifted)
                room.entities[i].rect = room.entities[i].rect.map(shifted)
            }
        case let .light(id):
            if let i = room.lights.firstIndex(where: { $0.id == id }) { room.lights[i].at = shifted(room.lights[i].at) }
        case let .spawn(id):
            if let i = room.spawns.firstIndex(where: { $0.id == id }) { room.spawns[i].at = shifted(room.spawns[i].at) }
        case let .line(id, _):
            if let i = room.collision.firstIndex(where: { $0.id == id }) { room.collision[i].points = room.collision[i].points.map(shifted) }
        case let .point(id, index):
            if let i = room.collision.firstIndex(where: { $0.id == id }), index < room.collision[i].points.count {
                room.collision[i].points[index] = [Int(p.x.rounded()), Int(p.y.rounded())]
            }
        }
        return room
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let d = drag, d.moved, let hit = d.hit, let model else { return }
        let p = roomPoint(event)
        let (dx, dy) = (Int((p.x - d.start.x).rounded()), Int((p.y - d.start.y).rounded()))
        switch hit {
        case let .entity(id): model.moveEntity(id, by: dx, dy)
        case let .light(id): model.moveLight(id, by: dx, dy)
        case let .spawn(id): model.moveSpawn(id, by: dx, dy)
        case let .line(id, _): model.moveLine(id, by: dx, dy)
        case let .point(id, index): model.movePoint(id, index, to: p)
        }
        // Refused or not, what's drawn is what the room is.
        build(room: model.room)
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .draw, !draft.isEmpty else { return }
        pointer = roomPoint(event)
        drawDraft()
    }

    /// The line being drawn, made: two points at least.
    private func finishDraft() {
        if draft.count >= 2 { model?.addLine(draft) }
        draft = []
        pointer = nil
        drawDraft()
    }

    override func scrollWheel(with event: NSEvent) {
        guard editing else { return }
        if event.modifierFlags.contains(.command) {
            zoomBy(1 + event.scrollingDeltaY * 0.01, at: event)
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            center.x -= event.scrollingDeltaX * k / zoom
            center.y -= event.scrollingDeltaY * k / zoom
            place()
        }
    }

    override func magnify(with event: NSEvent) {
        guard editing else { return }
        zoomBy(1 + event.magnification, at: event)
    }

    /// Zoomed by `factor` about the pointer.
    private func zoomBy(_ factor: CGFloat, at event: NSEvent) {
        let before = roomPoint(event)
        zoom = max(0.02, min(8, zoom * factor))
        let after = roomPoint(event)
        center.x += before.x - after.x
        center.y += before.y - after.y
        place()
        drawDraft()
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        if model.playing {
            if event.keyCode == 53 { return model.stop() }
            if !event.isARepeat, let name = Self.keyName(event.keyCode) { model.key(name, down: true) }
            return
        }
        switch event.keyCode {
        case 36, 76:
            if tool == .draw { finishDraft() }
        case 51, 117:
            model.removeSelected()
        case 53:
            if !draft.isEmpty {
                draft = []
                drawDraft()
            } else if tool != .select {
                model.tool = .select
            } else {
                model.selection = nil
            }
        default:
            let character = event.charactersIgnoringModifiers ?? ""
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if character == "f" { return fitRoom() }
                if model.toolKey(character) { return }
            }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let model, model.playing, let name = Self.keyName(event.keyCode) else { return super.keyUp(with: event) }
        model.key(name, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let model, model.playing else { return super.flagsChanged(with: event) }
        model.key("ShiftLeft", down: event.modifierFlags.contains(.shift))
    }

    /// The web's name for a key (`KeyZ`, `ArrowLeft`), as Proton's games
    /// name their keys.
    static func keyName(_ code: UInt16) -> String? {
        let letters: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
                                         45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z"]
        if let letter = letters[code] { return "Key\(letter)" }
        switch code {
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 49: return "Space"
        case 36: return "Enter"
        case 48: return "Tab"
        default: return nil
        }
    }

    // MARK: Playing

    private func startPlay() {
        playRoom = -1
        lastTime = 0
        draft = []
        window?.makeFirstResponder(self)
        link = displayLink(target: self, selector: #selector(frame(_:)))
        link?.add(to: .main, forMode: .common)
        drawPlay(alpha: 1)
    }

    private func stopPlay() {
        link?.invalidate()
        link = nil
        fade.opacity = 0
        build(room: model?.room)
        fitRoom()
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let model, let player = model.player else { return }
        let now = link.timestamp
        let elapsed = lastTime == 0 ? 0 : now - lastTime
        lastTime = now
        let alpha = player.advance(by: elapsed)
        _ = player.takeHappened()
        model.ticked()
        drawPlay(alpha: alpha)
    }

    /// Where the game's view sits on the stage, in points, and the size it's
    /// drawn at, in pixels: as large as fits, and for pixel art a whole
    /// number of the game's pixels a pixel where the stage has room for it.
    static func letterbox(view: CGSize, in bounds: CGSize, scale: CGFloat, pixelArt: Bool) -> (frame: CGRect, pixels: CGSize) {
        let fit = min(bounds.width * scale / view.width, bounds.height * scale / view.height)
        let k = pixelArt && fit >= 1 ? fit.rounded(.down) : fit
        let pixels = CGSize(width: (view.width * k).rounded(), height: (view.height * k).rounded())
        let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        return (CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height), pixels)
    }

    /// The run's frame drawn, eased `alpha` of the way from the one before:
    /// the camera following the player, what the run draws standing on the
    /// play plane, the lights wavering on the run's clock, and the game's
    /// finish. Pixel art is drawn at the game's own size, on its grid, then
    /// scaled up.
    private func drawPlay(alpha: Double) {
        guard let model, let player = model.player, let renderer else { return }
        let now = player.now
        let ids = player.info.rooms
        guard now.room < ids.count else { return }
        if now.room != playRoom {
            playRoom = now.room
            build(room: model.document?.room(ids[now.room]))
        }
        guard let room = drawnRoom, bounds.width > 0, bounds.height > 0 else { return }
        let before = player.before.flatMap { $0.room == now.room ? $0 : nil }
        func ease(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
        }
        let view = gameView
        let box = Self.letterbox(view: view, in: bounds.size, scale: scale, pixelArt: pixelArt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = box.frame
        metal.contentsScale = scale
        metal.drawableSize = box.pixels
        fade.frame = box.frame
        // Through a door: out to black over its first half, back over the second.
        let door = now.door
        fade.opacity = door == 0 ? 0 : Float(door <= 12 ? Double(door) / 12 : Double(24 - door) / 12)
        CATransaction.commit()

        var was: [Int: GameDrawn] = [:]
        for d in before?.drawn ?? [] { was[d.who] = d }
        let art = model.images.art
        let standing = now.drawn.map { d -> GameStanding in
            let at = was[d.who].map { ease($0.at, d.at) } ?? d.at
            guard d.sprite >= 0, d.sprite < player.info.sprites.count else {
                // A shot with no image of its own: a glow.
                return GameStanding(key: GameSprite.glow, at: at, pivot: .zero, glow: 24)
            }
            let key = player.info.sprites[d.sprite]
            var pivot = d.pivot
            // A shot is drawn about its middle.
            if d.who >= 1 << 20, let size = art.size(key) { pivot = CGPoint(x: size.width / 2, y: size.height / 2) }
            return GameStanding(key: key, at: at, pivot: pivot, flip: d.flip, frame: key.hasSuffix(".anim.json") && d.frame >= 0 ? d.frame : nil,
                                flash: d.flash, blink: d.blink)
        }
        let camera = before.map { ease($0.camera, now.camera) } ?? now.camera
        let time = (Double(now.tick) + alpha) / Double(max(1, player.info.tick))
        // Pixel art at the game's own size, the camera on its grid.
        let picture = pixelArt ? view : box.pixels
        var eye = GameCamera(center: camera, zoom: picture.width / view.width)
        if pixelArt { eye = eye.snapped(target: picture) }
        var job = GameRenderer.Job(sprites: GameScene.layout(room, focal: focal, view: view, center: eye.center, art: art, standing: standing, time: time, snap: pixelArt),
                                   camera: eye, post: model.document?.view.game.post, pixelArt: pixelArt, pictureSize: pixelArt ? view : nil)
        job.lighting = GameScene.lighting(room, focal: focal, view: view, center: eye.center, time: time)
        guard let drawable = metal.nextDrawable() else { return }
        metal.presentsWithTransaction = false
        renderer.draw(job, images: model.images, into: drawable, presentsWithTransaction: false)
    }
}
