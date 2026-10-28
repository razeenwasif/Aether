import MetalKit
import ModelCore
import SwiftUI

/// The Metal viewport, edge to edge. What changes it — the camera, the
/// object chosen, the scene's revision — is passed in, so a change draws a
/// frame and nothing else does.
struct ModelViewport: NSViewRepresentable {
    let model: ModelWorkspaceModel
    let camera: OrbitCamera
    let selected: String?
    let revision: Int
    /// Edit mode's: what's chosen and the mesh, so a change draws.
    let editRevision: Int

    final class Coordinator {
        var renderer: ModelRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ModelMTKView {
        let view = ModelMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.model = model
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = ModelRenderer.sampleCount
        // obsidian.0, the viewport's ground.
        view.clearColor = MTLClearColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)
        view.preferredFramesPerSecond = 120
        // Drawn on a change, not every frame: a still scene costs nothing.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        if let device = view.device, let renderer = ModelRenderer(device: device) {
            renderer.model = model
            view.delegate = renderer
            context.coordinator.renderer = renderer
        } else {
            model.notice = "This Mac's GPU couldn’t start the viewport."
        }
        return view
    }

    func updateNSView(_ view: ModelMTKView, context: Context) {
        view.needsDisplay = true
    }
}

/// The viewport's view: the pointer turns, slides and zooms the camera, and
/// a click chooses what's under it — Proton's controls, and a trackpad's. In
/// Edit mode a drag from what's chosen slides it along its normal (⌥ pulls
/// the chosen faces out first), and ⇧-click adds to what's chosen.
final class ModelMTKView: MTKView {
    weak var model: ModelWorkspaceModel?
    private var last: CGPoint?
    private var moved: CGFloat = 0
    private var panning = false
    private var sliding = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        last = point(event)
        moved = 0
        panning = event.modifierFlags.contains(.shift)
        sliding = !panning && model?.editing != nil
            && model?.pressToSlide(at: point(event), in: bounds.size, extruding: event.modifierFlags.contains(.option)) == true
    }

    override func mouseDragged(with event: NSEvent) {
        guard sliding else { return drag(event) }
        let p = point(event)
        if let from = last { moved += abs(p.x - from.x) + abs(p.y - from.y) }
        last = p
        model?.dragSlide(to: p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { last = nil }
        if sliding {
            sliding = false
            model?.endSlide()
            // A press on what's chosen that didn't move is a click on it.
            guard moved <= 4 else { return }
        }
        // A drag that ends over an object is a drag, not a click on it.
        guard moved <= 4, let model else { return }
        model.pick(at: point(event), in: bounds.size, adding: event.modifierFlags.contains(.shift))
    }

    override func rightMouseDown(with event: NSEvent) {
        last = point(event)
        moved = 0
        panning = true
    }

    override func rightMouseDragged(with event: NSEvent) { drag(event) }
    override func otherMouseDown(with event: NSEvent) { rightMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { drag(event) }

    private func drag(_ event: NSEvent) {
        guard let model, let from = last else { return }
        let p = point(event)
        let (dx, dy) = (Float(p.x - from.x), Float(p.y - from.y))
        last = p
        moved += abs(p.x - from.x) + abs(p.y - from.y)
        if panning { model.camera.pan(dx: dx, dy: dy) } else { model.camera.orbit(dx: dx, dy: -dy) }
    }

    /// Two fingers turn it (⇧, slide it); a mouse's wheel zooms.
    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        if event.hasPreciseScrollingDeltas {
            let (dx, dy) = (Float(event.scrollingDeltaX), Float(event.scrollingDeltaY))
            if event.modifierFlags.contains(.shift) { model.camera.pan(dx: -dx, dy: -dy) } else { model.camera.orbit(dx: -dx, dy: dy) }
        } else if event.scrollingDeltaY != 0 {
            model.camera.zoom(by: event.scrollingDeltaY > 0 ? 1 / 1.12 : 1.12)
        }
    }

    override func magnify(with event: NSEvent) {
        model?.camera.zoom(by: Float(1 / (1 + event.magnification)))
    }
}
