import AppKit
import CoreImage
import GameCore
import QuartzCore
import SwiftUI

/// The stage: a room drawn as the game's camera sees it, a layer an image,
/// so a camera move is only layers moved and the GPU composites them.
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
/// frame the run is at), and the overlays are gone. Ticks run on a fixed
/// clock off the display link, and what is drawn between two ticks is eased
/// between them.
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

    func makeNSView(context: Context) -> GameStageView {
        let view = GameStageView()
        view.model = model
        return view
    }

    func updateNSView(_ view: GameStageView, context: Context) {
        view.model = model
        view.insets = insets
        view.tool = tool
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

    /// The editor's camera: the room point at the stage's middle, and stage
    /// points a room pixel.
    private var center = CGPoint(x: 960, y: 540)
    private var zoom: CGFloat = 0.3
    private var shown: (revision: Int, room: String?, selection: GameSelection?, playing: Bool, fit: Int)?
    /// A fit asked for before the stage had a size: made once it has one.
    private var fitPending = false

    private let root = CALayer()
    /// Everything in room pixels: scaled and moved as the camera says.
    private let scene = CALayer()
    /// A layer a plane, each moved by its parallax.
    private var planes: [(plane: GamePlane, layer: CALayer)] = []
    /// What's drawn over the play plane while editing, and its layers by
    /// what they mark, to move with a drag.
    private let overlay = CALayer()
    private var lines: [CAShapeLayer] = []
    private var marks: [String: [CALayer]] = [:]
    /// The line being drawn, and where the pointer is.
    private var draft: [CGPoint] = []
    private var pointer: CGPoint?
    private let draftLayer = CAShapeLayer()
    /// What a run draws, by who it is.
    private let standing = CALayer()
    private var actors: [Int: CALayer] = [:]
    /// The halos of the room's lights.
    private let halos = CALayer()
    /// In Play, the stage outside the game's view covered, as Proton
    /// letterboxes it: the room past the view isn't the game's to show.
    private let bars = CAShapeLayer()
    /// A door's fade, over everything.
    private let fade = CALayer()
    private var drawnRoom: GameRoom?
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var playRoom = -1
    private var drag: (start: CGPoint, hit: GameHit?, moved: Bool)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.backgroundColor = NSColor(calibratedRed: 0.028, green: 0.031, blue: 0.04, alpha: 1).cgColor
        root.isGeometryFlipped = true
        root.masksToBounds = true
        scene.anchorPoint = .zero
        root.addSublayer(scene)
        draftLayer.fillColor = nil
        draftLayer.lineDashPattern = [12, 8]
        bars.fillColor = root.backgroundColor
        bars.fillRule = .evenOdd
        bars.isHidden = true
        root.addSublayer(bars)
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

    override func layout() {
        super.layout()
        fade.frame = bounds
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
    private var pixelArt: Bool { model?.document?.view.game.view.filter == "pixel" }
    private var editing: Bool { model?.playing != true }

    /// The room's layers made again: its planes and their art, its lights'
    /// halos, and, editing, what's drawn over them.
    private func build(room: GameRoom?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scene.sublayers?.forEach { $0.removeFromSuperlayer() }
        bars.isHidden = editing
        planes = []
        actors = [:]
        lines = []
        marks = [:]
        for layer in [overlay, standing, halos] { layer.sublayers?.forEach { $0.removeFromSuperlayer() } }
        drawnRoom = room
        guard let room, let images = model?.images else { return }
        for plane in room.planes {
            let layer = CALayer()
            layer.anchorPoint = .zero
            let haze = GameScene.haze(room, plane)
            for item in plane.items {
                guard let image = images.image(item.image) else { continue }
                layer.addSublayer(itemLayer(item, image: image, planeBlend: plane.blend, haze: haze))
            }
            if plane.gameplay { attachPlay(to: layer) }
            for light in room.lights where light.plane == plane.id && light.glow > 0 {
                halos.addSublayer(halo(light))
            }
            scene.addSublayer(layer)
            planes.append((plane, layer))
        }
        if !planes.contains(where: { $0.plane.gameplay }) { attachPlay(to: scene) }
        if editing {
            // Over every plane, foreground and all: the play plane doesn't
            // shift, so its room pixels are the scene's.
            scene.addSublayer(overlay)
            scene.addSublayer(draftLayer)
            buildOverlay(room)
        }
        place()
    }

    /// What stands on the play plane: the run's things and the halos.
    private func attachPlay(to layer: CALayer) {
        layer.addSublayer(standing)
        layer.addSublayer(halos)
    }

    private func itemLayer(_ item: GameItem, image: CGImage, planeBlend: String, haze: (Double, Double, Double, Double)) -> CALayer {
        let layer = CALayer()
        let size = CGSize(width: Double(image.width) * item.scale, height: Double(image.height) * item.scale)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: Double(item.at[0]) + size.width / 2, y: Double(item.at.count > 1 ? item.at[1] : 0) + size.height / 2)
        layer.contents = image
        layer.contentsGravity = .resize
        layer.opacity = Float(item.opacity)
        if pixelArt { layer.magnificationFilter = .nearest }
        var t = CATransform3DMakeRotation(item.rot * .pi / 180, 0, 0, 1)
        if item.flip { t = CATransform3DScale(t, -1, 1, 1) }
        layer.transform = t
        Self.blend(layer, item.blend != "normal" ? item.blend : planeBlend)
        // The haze of distance: the fog's colour over the art, through the
        // art's own shape.
        if haze.3 > 0 {
            let tint = CALayer()
            tint.frame = layer.bounds
            tint.backgroundColor = CGColor(red: haze.0, green: haze.1, blue: haze.2, alpha: haze.3)
            let mask = CALayer()
            mask.frame = layer.bounds
            mask.contents = image
            mask.contentsGravity = .resize
            tint.mask = mask
            layer.addSublayer(tint)
        }
        return layer
    }

    private static func blend(_ layer: CALayer, _ blend: String) {
        switch blend {
        case "add": layer.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        case "multiply": layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        case "screen": layer.compositingFilter = CIFilter(name: "CIScreenBlendMode")
        default: break
        }
    }

    /// A light's halo in the air round it: its colour, fading out, added.
    private func halo(_ light: GameLight) -> CALayer {
        let (r, g, b) = GameScene.rgb(light.color)
        let strength = min(1, light.glow * light.intensity)
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [CGColor(red: r, green: g, blue: b, alpha: strength), CGColor(red: r, green: g, blue: b, alpha: 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        let reach = Double(light.radius) * 0.6
        glow.frame = CGRect(x: Double(light.at[0]) - reach, y: Double(light.at.count > 1 ? light.at[1] : 0) - reach, width: reach * 2, height: reach * 2)
        glow.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        marks["light:\(light.id)", default: []].append(glow)
        return glow
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
                if let sprite = restingSprite(entity, at: CGPoint(x: at[0], y: at[1])) { mark(key, sprite) }
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

    /// What a thing standing in the room looks like while editing: its
    /// prefab's image, or its animation's resting frame, on its feet.
    private func restingSprite(_ entity: GameEntity, at: CGPoint) -> CALayer? {
        guard let prefab = model?.document?.view.prefab(entity.prefab), let images = model?.images else { return nil }
        let pivot = CGPoint(x: prefab.pivot.first ?? 0, y: prefab.pivot.count > 1 ? prefab.pivot[1] : 0)
        let sprite = CALayer()
        if pixelArt { sprite.magnificationFilter = .nearest }
        if prefab.animated, let anim = images.anim(prefab.sprite), let (image, frame) = images.frame(prefab.sprite, anim.restingFrame(prefab.clips)) {
            sprite.contents = image
            sprite.frame = GameScene.animFrame(frame, at: at, pivot: pivot, flip: false)
        } else if let image = images.image(prefab.sprite) {
            sprite.contents = image
            sprite.frame = GameScene.stillFrame(size: CGSize(width: image.width, height: image.height), at: at, pivot: pivot, flip: false)
        } else {
            return nil
        }
        return sprite
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

    /// The editor's camera applied: the scene scaled and moved, each plane
    /// shifted by its parallax for the game camera at the stage's middle,
    /// and the lines and handles kept the same size on screen.
    private func place() {
        guard let room = drawnRoom else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position(center: center, zoom: zoom, room: room)
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
        CATransaction.commit()
    }

    private func position(center: CGPoint, zoom: CGFloat, room: GameRoom) {
        scene.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        scene.position = CGPoint(x: bounds.width / 2 - center.x * zoom, y: bounds.height / 2 - center.y * zoom)
        let corner = GameScene.corner(room, view: gameView, center: center)
        for (plane, layer) in planes {
            layer.position = GameScene.shift(GameScene.factor(plane, focal: focal), corner: corner)
        }
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
                if let sprite = restingSprite(entity, at: feet), sprite.frame.contains(p) { return .entity(entity.id) }
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

    /// The run's frame drawn, eased `alpha` of the way from the one before.
    private func drawPlay(alpha: Double) {
        guard let model, let player = model.player else { return }
        let now = player.now
        let ids = player.info.rooms
        guard now.room < ids.count else { return }
        if now.room != playRoom {
            playRoom = now.room
            build(room: model.document?.room(ids[now.room]))
        }
        guard let room = drawnRoom, bounds.width > 0 else { return }
        let before = player.before.flatMap { $0.room == now.room ? $0 : nil }
        func ease(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
        }
        let camera = before.map { ease($0.camera, now.camera) } ?? now.camera
        let view = gameView
        let zoom = min(bounds.width / view.width, bounds.height / view.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position(center: camera, zoom: zoom, room: room)
        let shown = CGSize(width: view.width * zoom, height: view.height * zoom)
        let bare = CGMutablePath()
        bare.addRect(bounds)
        bare.addRect(CGRect(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2, width: shown.width, height: shown.height))
        bars.path = bare
        var was: [Int: GameDrawn] = [:]
        for d in before?.drawn ?? [] { was[d.who] = d }
        var seen = Set<Int>()
        for d in now.drawn {
            seen.insert(d.who)
            let at = was[d.who].map { ease($0.at, d.at) } ?? d.at
            let layer = actors[d.who] ?? {
                let made = CALayer()
                if pixelArt { made.magnificationFilter = .nearest }
                standing.addSublayer(made)
                actors[d.who] = made
                return made
            }()
            let key = d.sprite >= 0 && d.sprite < player.info.sprites.count ? player.info.sprites[d.sprite] : nil
            var drawn = false
            if let key, key.hasSuffix(".anim.json"), let (image, frame) = model.images.frame(key, max(0, d.frame)) {
                // An animation: the frame the run is at, on its feet.
                show(layer, image, in: GameScene.animFrame(frame, at: at, pivot: d.pivot, flip: d.flip))
                drawn = true
            } else if let key, let image = model.images.image(key) {
                let size = CGSize(width: image.width, height: image.height)
                // A shot is drawn about its middle.
                let pivot = d.who >= 1 << 20 ? CGPoint(x: size.width / 2, y: size.height / 2) : d.pivot
                show(layer, image, in: GameScene.stillFrame(size: size, at: at, pivot: pivot, flip: d.flip))
                drawn = true
            }
            if !drawn {
                // A shot with no image of its own: a glow.
                layer.contents = nil
                layer.backgroundColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.4, alpha: 0.9).cgColor
                layer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
                layer.cornerRadius = 9
                layer.position = at
                layer.transform = CATransform3DIdentity
            } else {
                layer.transform = d.flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            }
            layer.opacity = d.blink ? 0.35 : 1
            layer.compositingFilter = d.flash ? CIFilter(name: "CIColorDodgeBlendMode") : nil
        }
        for (who, layer) in actors where !seen.contains(who) {
            layer.removeFromSuperlayer()
            actors[who] = nil
        }
        // Through a door: out to black over its first half, back over the second.
        let door = now.door
        fade.opacity = door == 0 ? 0 : Float(door <= 12 ? Double(door) / 12 : Double(24 - door) / 12)
        CATransaction.commit()
    }

    /// An image put in a frame: mirrored about its middle when flipped,
    /// which with the frame worked out flip-aware turns it on its feet.
    private func show(_ layer: CALayer, _ image: CGImage, in frame: CGRect) {
        if layer.contents == nil || (layer.contents as! CGImage) !== image { layer.contents = image }
        layer.backgroundColor = nil
        layer.cornerRadius = 0
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
    }
}
