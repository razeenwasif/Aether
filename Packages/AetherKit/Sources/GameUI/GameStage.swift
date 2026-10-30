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
/// Proton's window did the same. Collision, the things in the room and the
/// spawns are drawn over the play plane; a thing is chosen with a click and
/// moved with a drag, one step each.
///
/// Playing, the run's frame decides it all: the camera follows the
/// player, what the run draws stands on the play plane, and the overlays
/// are gone. Ticks run on a fixed clock off the display link, and what is
/// drawn between two ticks is eased between them.
struct GameStage: NSViewRepresentable {
    let model: GameWorkspaceModel
    /// What, changed, means the room must be laid out again.
    let revision: Int
    let roomID: String?
    let selected: String?
    let playing: Bool
    let fitRequest: Int
    /// How much of the stage the panels cover, left and right: a room is
    /// fitted into what's left.
    let insets: (left: CGFloat, right: CGFloat)

    func makeNSView(context: Context) -> GameStageView {
        let view = GameStageView()
        view.model = model
        return view
    }

    func updateNSView(_ view: GameStageView, context: Context) {
        view.model = model
        view.insets = insets
        view.update(revision: revision, roomID: roomID, selected: selected, playing: playing, fit: fitRequest)
    }
}

final class GameStageView: NSView {
    weak var model: GameWorkspaceModel?

    /// The editor's camera: the room point at the stage's middle, and stage
    /// points a room pixel.
    private var center = CGPoint(x: 960, y: 540)
    private var zoom: CGFloat = 0.3
    private var shown: (revision: Int, room: String?, selected: String?, playing: Bool, fit: Int)?
    var insets: (left: CGFloat, right: CGFloat) = (0, 0)
    /// A fit asked for before the stage had a size: made once it has one.
    private var fitPending = false

    private let root = CALayer()
    /// Everything in room pixels: scaled and moved as the camera says.
    private let scene = CALayer()
    /// A layer a plane, each moved by its parallax.
    private var planes: [(plane: GamePlane, layer: CALayer)] = []
    /// What's drawn over the play plane while editing.
    private let overlay = CALayer()
    private var lines: [CAShapeLayer] = []
    /// What a run draws, by who it is.
    private let standing = CALayer()
    private var actors: [Int: CALayer] = [:]
    /// A door's fade, over everything.
    private let fade = CALayer()
    private var drawnRoom: GameRoom?
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var playRoom = -1
    private var drag: (start: CGPoint, last: CGPoint, entity: String?, moved: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.backgroundColor = NSColor(calibratedRed: 0.028, green: 0.031, blue: 0.04, alpha: 1).cgColor
        root.isGeometryFlipped = true
        root.masksToBounds = true
        scene.anchorPoint = .zero
        root.addSublayer(scene)
        fade.backgroundColor = NSColor.black.cgColor
        fade.opacity = 0
        root.addSublayer(fade)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        fade.frame = bounds
        if model?.playing == true { drawPlay(alpha: 1) } else if fitPending { fitRoom() } else { place() }
    }

    func update(revision: Int, roomID: String?, selected: String?, playing: Bool, fit: Int) {
        let was = shown
        shown = (revision, roomID, selected, playing, fit)
        if playing != was?.playing {
            playing ? startPlay() : stopPlay()
        }
        if !playing, was?.revision != revision || was?.room != roomID || was?.selected != selected || was?.playing != playing {
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

    /// The room's layers made again: its planes and their art, and, editing,
    /// what's drawn over them.
    private func build(room: GameRoom?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scene.sublayers?.forEach { $0.removeFromSuperlayer() }
        planes = []
        actors = [:]
        lines = []
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        standing.sublayers?.forEach { $0.removeFromSuperlayer() }
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
            if plane.gameplay {
                layer.addSublayer(standing)
                if model?.playing != true { layer.addSublayer(overlay) }
            }
            scene.addSublayer(layer)
            planes.append((plane, layer))
        }
        if !planes.contains(where: { $0.plane.gameplay }) {
            scene.addSublayer(standing)
            if model?.playing != true { scene.addSublayer(overlay) }
        }
        if model?.playing != true { buildOverlay(room) }
        place()
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

    /// Collision as lines by kind, the things in the room, and the spawns.
    private func buildOverlay(_ room: GameRoom) {
        let colours: [String: NSColor] = [
            "solid": NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 0.95),
            "oneway": NSColor(calibratedRed: 0.5, green: 0.95, blue: 0.6, alpha: 0.95),
            "hazard": NSColor(calibratedRed: 1, green: 0.4, blue: 0.4, alpha: 0.95),
            "nowall": NSColor(calibratedRed: 1, green: 0.8, blue: 0.4, alpha: 0.95),
        ]
        for shape in room.collision where shape.points.count >= 2 {
            let path = CGMutablePath()
            path.addLines(between: shape.points.map { CGPoint(x: $0[0], y: $0.count > 1 ? $0[1] : 0) })
            if shape.closed { path.closeSubpath() }
            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = (colours[shape.kind] ?? colours["solid"]!).cgColor
            if shape.kind == "oneway" { line.lineDashPattern = [10, 6] }
            overlay.addSublayer(line)
            lines.append(line)
        }
        let ice = NSColor(calibratedRed: 0.6, green: 0.78, blue: 1, alpha: 1)
        for entity in room.entities {
            let chosen = entity.id == model?.selected
            if let r = entity.rect, r.count == 4 {
                let box = CAShapeLayer()
                box.path = CGPath(rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), transform: nil)
                box.fillColor = ice.withAlphaComponent(chosen ? 0.22 : 0.08).cgColor
                box.strokeColor = ice.withAlphaComponent(chosen ? 1 : 0.6).cgColor
                box.lineDashPattern = chosen ? nil : [8, 6]
                overlay.addSublayer(box)
                lines.append(box)
                overlay.addSublayer(label(entity.id, at: CGPoint(x: r[0], y: r[1] - 30), chosen: chosen))
            } else if let at = entity.at, at.count == 2 {
                let prefab = model?.document?.view.prefab(entity.prefab)
                if let prefab, let image = model?.images.image(prefab.sprite) {
                    let sprite = CALayer()
                    sprite.contents = image
                    sprite.frame = CGRect(x: at[0] - prefab.pivot[0], y: at[1] - (prefab.pivot.count > 1 ? prefab.pivot[1] : 0), width: image.width, height: image.height)
                    if pixelArt { sprite.magnificationFilter = .nearest }
                    overlay.addSublayer(sprite)
                }
                let mark = CAShapeLayer()
                let radius: CGFloat = 18
                mark.path = CGPath(ellipseIn: CGRect(x: CGFloat(at[0]) - radius, y: CGFloat(at[1]) - radius, width: radius * 2, height: radius * 2), transform: nil)
                mark.fillColor = ice.withAlphaComponent(chosen ? 0.35 : 0.12).cgColor
                mark.strokeColor = ice.withAlphaComponent(chosen ? 1 : 0.7).cgColor
                overlay.addSublayer(mark)
                lines.append(mark)
                overlay.addSublayer(label(entity.id, at: CGPoint(x: at[0] - 40, y: at[1] + 22), chosen: chosen))
            }
        }
        for spawn in room.spawns where spawn.at.count == 2 {
            let mark = CAShapeLayer()
            let p = CGPoint(x: spawn.at[0], y: spawn.at[1])
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p.x - 14, y: p.y))
            path.addLine(to: CGPoint(x: p.x + 14, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - 28))
            path.addLine(to: CGPoint(x: p.x, y: p.y))
            mark.path = path
            mark.strokeColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.45, alpha: 0.95).cgColor
            overlay.addSublayer(mark)
            lines.append(mark)
            overlay.addSublayer(label("spawn \(spawn.id)", at: CGPoint(x: p.x + 8, y: p.y - 40), chosen: false))
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

    // MARK: Placing

    /// The editor's camera applied: the scene scaled and moved, each plane
    /// shifted by its parallax for the game camera at the stage's middle.
    private func place() {
        guard let room = drawnRoom else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position(center: center, zoom: zoom, room: room)
        let width = 2 / zoom
        for line in lines { line.lineWidth = width }
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
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - bounds.width / 2) / zoom + center.x, y: (p.y - bounds.height / 2) / zoom + center.y)
    }

    // MARK: Editing by hand

    private func entity(at p: CGPoint) -> String? {
        guard let room = drawnRoom else { return nil }
        let reach = 24 / zoom
        for entity in room.entities.reversed() {
            if let at = entity.at, at.count == 2 {
                let prefab = model?.document?.view.prefab(entity.prefab)
                if let prefab, let image = model?.images.image(prefab.sprite) {
                    let r = CGRect(x: at[0] - prefab.pivot[0], y: at[1] - (prefab.pivot.count > 1 ? prefab.pivot[1] : 0), width: image.width, height: image.height)
                    if r.contains(p) { return entity.id }
                }
                if hypot(p.x - CGFloat(at[0]), p.y - CGFloat(at[1])) <= max(reach, 18) { return entity.id }
            } else if let r = entity.rect, r.count == 4, CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -reach / 2, dy: -reach / 2).contains(p) {
                return entity.id
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard model?.playing != true else { return }
        let p = roomPoint(event)
        let hit = entity(at: p)
        model?.selected = hit
        drag = (p, p, hit, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, model?.playing != true else { return }
        let p = roomPoint(event)
        if d.entity != nil {
            // The thing follows the pointer; the step is made on release.
            let dx = p.x - d.start.x, dy = p.y - d.start.y
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.setAffineTransform(.identity)
            movePreview(dx: dx, dy: dy)
            CATransaction.commit()
        } else {
            // Nothing under it: the room moves.
            let screen = convert(event.locationInWindow, from: nil)
            let last = CGPoint(x: (d.last.x - center.x) * zoom + bounds.width / 2, y: (d.last.y - center.y) * zoom + bounds.height / 2)
            center.x -= (screen.x - last.x) / zoom
            center.y -= (screen.y - last.y) / zoom
            place()
            d.last = roomPoint(event)
            drag = d
            return
        }
        d.last = p
        d.moved = true
        drag = d
    }

    /// While a thing is dragged, its marks are moved with it.
    private var previewed: [CALayer] = []
    private func movePreview(dx: CGFloat, dy: CGFloat) {
        guard let id = drag?.entity, let room = drawnRoom, let entity = room.entity(id) else { return }
        if previewed.isEmpty {
            // The overlay's layers for it: those near where it was.
            let anchor = entity.at.map { CGPoint(x: $0[0], y: $0[1]) } ?? entity.rect.map { CGPoint(x: $0[0], y: $0[1]) } ?? .zero
            previewed = (overlay.sublayers ?? []).filter { layer in
                let box = (layer as? CAShapeLayer)?.path?.boundingBox ?? layer.frame
                return box.insetBy(dx: -60, dy: -60).contains(anchor) || box.contains(CGPoint(x: anchor.x, y: anchor.y))
            }
        }
        for layer in previewed { layer.setAffineTransform(CGAffineTransform(translationX: dx, y: dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            previewed = []
        }
        guard let d = drag, d.moved, let id = d.entity else { return }
        let p = roomPoint(event)
        model?.moveEntity(id, by: Int((p.x - d.start.x).rounded()), Int((p.y - d.start.y).rounded()))
    }

    override func scrollWheel(with event: NSEvent) {
        guard model?.playing != true else { return }
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
        guard model?.playing != true else { return }
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
    }

    override func keyDown(with event: NSEvent) {
        if let model, model.playing {
            if event.keyCode == 53 { return model.stop() }
            if !event.isARepeat, let name = Self.keyName(event.keyCode) { model.key(name, down: true) }
            return
        }
        switch event.keyCode {
        case 51, 117: model?.removeSelected()
        case 53: model?.selected = nil
        default:
            if event.charactersIgnoringModifiers == "f" { fitRoom() } else { super.keyDown(with: event) }
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
            if d.sprite >= 0, d.sprite < player.info.sprites.count, let image = model.images.image(player.info.sprites[d.sprite]) {
                if layer.contents == nil || (layer.contents as! CGImage) !== image { layer.contents = image }
                layer.backgroundColor = nil
                layer.cornerRadius = 0
                let shot = d.who >= 1 << 20
                let pivot = shot ? CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2) : d.pivot
                layer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                layer.position = CGPoint(x: at.x - pivot.x + Double(image.width) / 2, y: at.y - pivot.y + Double(image.height) / 2)
            } else {
                // A shot with no image of its own: a glow.
                layer.contents = nil
                layer.backgroundColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.4, alpha: 0.9).cgColor
                layer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
                layer.cornerRadius = 9
                layer.position = at
            }
            layer.transform = d.flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
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
}
