import PhotonGraph
import AppKit
import Foundation
import ImageIO
import Metal
import ModelCore
import simd
import UniformTypeIdentifiers

/// How big a render is.
public enum RenderSize: String, CaseIterable, Identifiable, Sendable {
    case square, wide, tall, large

    public var id: String { rawValue }
    public var pixels: (width: Int, height: Int) {
        switch self {
        case .square: (1024, 1024)
        case .wide: (1536, 1024)
        case .tall: (1024, 1536)
        case .large: (2048, 2048)
        }
    }
    public var title: String {
        let (w, h) = pixels
        return "\(w) × \(h)"
    }
}

/// How a render is made.
public enum RenderEngine: String, CaseIterable, Identifiable, Sendable {
    /// As the view draws: a moment.
    case quick
    /// Rays followed through the scene: bounced light, soft shadows,
    /// reflections; seconds.
    case traced

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .quick: "Quick"
        case .traced: "Path traced"
        }
    }
}

/// A render made: its pictures, where they were written, and the assets
/// they were published as.
public struct Rendered {
    public var beauty: CGImage
    public var depth: CGImage
    public var files: (beauty: URL, depth: URL)
    /// The versions published, when the scene is in a project.
    public var versions: (beauty: Int, depth: Int)?
    public var at: Date
}

/// Render (⌘↩): the scene from the camera, drawn offscreen as the viewport
/// draws it but larger and cleaner, and its depth pass. Both are written
/// beside the scene, in `renders/`, and published as the project's assets
/// "<Scene> Render" and "<Scene> Depth", so a flow's Load Image or a canvas
/// layer follows each new render.
extension ModelWorkspaceModel {
    /// The documents the two assets are made by: the scene's path, marked.
    public static func renderDocuments(of scenePath: String) -> (beauty: String, depth: String) {
        ("\(scenePath)#render", "\(scenePath)#depth")
    }

    /// The scene's path a render's asset names, without its mark.
    public static func scenePath(ofRender document: String) -> String {
        document.split(separator: "#", maxSplits: 1).first.map(String.init) ?? document
    }

    public func render() {
        guard let document else { return notice = "Open a scene to render it." }
        if renderer == nil, let device = MTLCreateSystemDefaultDevice() {
            renderer = ModelRenderer(device: device)
            renderer?.model = self
        }
        guard let renderer else { return notice = "This Mac’s GPU can’t render." }
        let (width, height) = renderSize.pixels
        if let id = renderCamera, document.node(id)?.kind != "camera" { renderCamera = nil }
        let settings = ModelRenderer.RenderSettings(width: width, height: height, transparent: renderTransparent, camera: renderCamera, floor: renderFloor, shadows: renderShadows, denoise: renderDenoise)
        guard renderTask == nil else { return }
        let traced = renderEngine == .traced
        if traced, !renderer.canTrace { return notice = "This Mac’s GPU can’t trace rays: the quick render is the one there is." }
        let samples = renderSamples
        stopRendering = false
        if traced {
            renderProgress = 0
            renderOpen = true
        }
        // Both engines run as a task: the GPU is waited for, and the pictures
        // encoded and written, off the main thread (§7b).
        renderTask = Task { [weak self] in
            defer {
                self?.renderTask = nil
                self?.renderProgress = nil
            }
            do {
                let pictures = traced
                    ? try await renderer.pathTrace(settings, samples: samples) { done in
                        guard let self else { return false }
                        self.renderProgress = done
                        return !self.stopRendering
                    }
                    : try await renderer.render(settings)
                guard let self, self.document === document else { return }
                await self.keep(pictures, width: width, height: height, scene: document)
            } catch {
                self?.notice = "Couldn’t render \(document.name): \(error.localizedDescription)"
            }
        }
    }

    /// A path-traced render stopped where it is: what it has so far is kept.
    public func stopRender() {
        stopRendering = true
    }

    /// Wait for a render under way to finish: drawn, written and shown.
    public func renderFinished() async {
        await renderTask?.value
    }

    /// A render's pictures encoded and written beside the scene off the main
    /// thread, then shown, and published.
    private func keep(_ pictures: ModelRenderer.Pictures, width: Int, height: Int, scene document: SceneDocument) async {
        let folder = document.folder.appending(path: "renders", directoryHint: .isDirectory)
        let files = (folder.appending(path: "\(document.name) render.png"), folder.appending(path: "\(document.name) depth.png"))
        let (beauty, depth) = (pictures.beauty, pictures.depth)
        do {
            let encoding = ModelRenderer.signposter.beginInterval("png")
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.png(beauty).write(to: files.0, options: .atomic)
                try Self.png(depth).write(to: files.1, options: .atomic)
            }.value
            ModelRenderer.signposter.endInterval("png", encoding)
        } catch {
            notice = "Couldn’t render \(document.name): \(error.localizedDescription)"
            return
        }
        lastRender = Rendered(beauty: beauty, depth: depth, files: files, versions: nil, at: Date())
        renderOpen = true
        publish(files, width: width, height: height, scene: document)
    }

    /// The two pictures as the project's assets, new versions of them.
    private func publish(_ files: (beauty: URL, depth: URL), width: Int, height: Int, scene: SceneDocument) {
        guard let project else {
            notice = "Rendered \(width) × \(height) into renders/ beside the scene."
            return
        }
        let path = project.path(of: scene.url)
        let documents = Self.renderDocuments(of: path)
        let name = scene.name
        Task { [weak self] in
            do {
                let beautyAsset = try project.asset(madeBy: documents.beauty, named: "\(name) Render", in: .model)
                let depthAsset = try project.asset(madeBy: documents.depth, named: "\(name) Depth", in: .model)
                // Cloned from the files just written, not written again.
                let a = try project.publish(beautyAsset.id, blob: try await project.pool.store(contentsOf: files.beauty), width: width, height: height, note: "rendered")
                let b = try project.publish(depthAsset.id, blob: try await project.pool.store(contentsOf: files.depth), width: width, height: height, note: "rendered")
                guard let self else { return }
                self.lastRender?.versions = (a.number, b.number)
                self.notice = "Rendered \(width) × \(height): \(name) Render and \(name) Depth, v\(a.number). A flow’s Load Image or a canvas can follow them: find them in the omnibar."
            } catch {
                self?.notice = "Rendered, but couldn’t publish it: \(error.localizedDescription)"
            }
        }
    }

    /// The scene's cameras, for a render to look through.
    public var cameras: [SceneNode] {
        document?.state.objects.filter { $0.kind == "camera" } ?? []
    }

    /// The chosen camera moved to where the view's camera is, looking where
    /// it looks, with the view's field of view: one step. Placing a camera by
    /// typing its turn is hopeless; framing the view and taking it is not.
    public func cameraFromView() {
        guard let node = selectedNode, node.kind == "camera" else { return }
        placeCamera(label: "\(node.name) from the View", joining: false, adopt: true)
    }

    /// The chosen camera put where the view is, as a step named `label`,
    /// joining the one before it when `joining` (a camera just added); with
    /// `adopt`, renders look through it from now on.
    func placeCamera(label: String, joining: Bool, adopt: Bool) {
        guard let document, let node = selectedNode, node.kind == "camera" else { return }
        let eye = camera.view.inverse
        // In the parent's space, so a camera under an empty lands right.
        let parent = SceneMath.worlds(document.state.objects)[node.parent] ?? matrix_identity_float4x4
        let local = parent.inverse * eye
        let turn = simd_float3x3(SIMD3(local.columns.0.x, local.columns.0.y, local.columns.0.z),
                                 SIMD3(local.columns.1.x, local.columns.1.y, local.columns.1.z),
                                 SIMD3(local.columns.2.x, local.columns.2.y, local.columns.2.z))
        let at = [local.columns.3.x, local.columns.3.y, local.columns.3.z].map { (Double($0) * 1e4).rounded() / 1e4 }
        // Three edits as one step, joined by their shared name.
        guard document.apply(.setTransform(node.id, part: .position, to: at), label: label, joining: joining) != nil,
              document.apply(.setTransform(node.id, part: .rotation, to: SceneMath.degrees(of: turn)), label: label, joining: true) != nil,
              document.apply(.setFov(node.id, degrees: (Double(SceneMath.fov) * 180 / .pi * 1e4).rounded() / 1e4), label: label, joining: true) != nil else {
            notice = document.refusal
            return
        }
        if adopt { renderCamera = node.id }
        scheduleSave()
    }

    public func setFov(_ degrees: Double) {
        guard let node = selectedNode else { return }
        change(.setFov(node.id, degrees: degrees), label: "Field of View")
    }

    /// Change the chosen light; the same change within a second joins its
    /// step, as a colour dragged does.
    public func editLight(_ label: String, _ edit: (inout SceneLight) -> Void) {
        guard let document, let node = selectedNode, var light = node.light else { return }
        let before = light
        edit(&light)
        guard light != before else { return }
        let key = "\(node.id)|\(label)"
        let now = Date()
        let joining = lastLayerEdit.map { $0.key == key && now.timeIntervalSince($0.at) < 1 } ?? false
        lastLayerEdit = (key, now)
        guard document.apply(.setLight(node.id, light: light), label: label, joining: joining) != nil else {
            notice = document.refusal
            return
        }
        scheduleSave()
    }

    /// The chosen light made a point or a sun, taking that kind's own
    /// strength (20 for a point, 3 for a sun) unless its had been changed.
    public func setLightKind(_ kind: String) {
        editLight("Light Kind") { one in
            if one.strength == (kind == "sun" ? 20 : 3) { one.strength = kind == "sun" ? 3 : 20 }
            one.kind = kind
        }
    }

    public func toggleRenderDrawer() {
        renderOpen.toggle()
    }

    /// The last render's files, shown in the Finder.
    public func revealRender() {
        guard let files = lastRender?.files else { return }
        NSWorkspace.shared.activateFileViewerSelecting([files.beauty, files.depth])
    }

    nonisolated static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
