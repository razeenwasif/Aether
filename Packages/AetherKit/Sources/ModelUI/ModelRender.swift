import AetherGraph
import AppKit
import Foundation
import ImageIO
import Metal
import ModelCore
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
        do {
            let pictures = try renderer.render(width: width, height: height, transparent: renderTransparent)
            let folder = document.folder.appending(path: "renders", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = (folder.appending(path: "\(document.name) render.png"), folder.appending(path: "\(document.name) depth.png"))
            let beautyPNG = try Self.png(pictures.beauty)
            let depthPNG = try Self.png(pictures.depth)
            try beautyPNG.write(to: files.0, options: .atomic)
            try depthPNG.write(to: files.1, options: .atomic)
            lastRender = Rendered(beauty: pictures.beauty, depth: pictures.depth, files: files, versions: nil, at: Date())
            renderOpen = true
            publish(beautyPNG, depthPNG, width: width, height: height, scene: document)
        } catch {
            notice = "Couldn’t render \(document.name): \(error.localizedDescription)"
        }
    }

    /// The two pictures as the project's assets, new versions of them.
    private func publish(_ beauty: Data, _ depth: Data, width: Int, height: Int, scene: SceneDocument) {
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
                let a = try project.publish(beautyAsset.id, blob: try await project.pool.store(beauty), width: width, height: height, note: "rendered")
                let b = try project.publish(depthAsset.id, blob: try await project.pool.store(depth), width: width, height: height, note: "rendered")
                guard let self else { return }
                self.lastRender?.versions = (a.number, b.number)
                self.notice = "Rendered \(width) × \(height): \(name) Render and \(name) Depth, v\(a.number). A flow’s Load Image or a canvas can follow them: find them in the omnibar."
            } catch {
                self?.notice = "Rendered, but couldn’t publish it: \(error.localizedDescription)"
            }
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

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
