import AetherDesign
import ModelCore
import SwiftUI

/// The render drawer: the last render and its depth pass side by side, and
/// how the next one is made.
struct RenderDrawer: View {
    @Bindable var model: ModelWorkspaceModel
    let document: SceneDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "camera.aperture").font(.system(size: 11)).foregroundStyle(Color.ink2)
                Text("Render").font(.aeBodyStrong).foregroundStyle(Color.inkHi)
                Picker("Engine", selection: $model.renderEngine) {
                    ForEach(RenderEngine.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Quick draws as the view does, in a moment; path traced follows light as it bounces, for soft shadows and reflections, in seconds")
                if model.renderEngine == .traced {
                    Picker("Samples", selection: $model.renderSamples) {
                        ForEach([32, 128, 512, 2048], id: \.self) { Text("\($0) samples").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .help("Rays a pixel: more is smoother and slower")
                }
                Picker("Size", selection: $model.renderSize) {
                    ForEach(RenderSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("How big a render is, in pixels; the view's camera, at this shape")
                Picker("Camera", selection: $model.renderCamera) {
                    Text("The view").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(String?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("What the render looks through: the view's camera, or one of the scene's")
                Spacer()
                if let done = model.renderProgress {
                    ProgressView(value: Double(done), total: Double(max(model.renderSamples, 1)))
                        .frame(width: 90)
                        .controlSize(.small)
                    Text(verbatim: "\(done)/\(model.renderSamples)").font(.aeMono).foregroundStyle(Color.ink2)
                    Button("Stop", action: model.stopRender)
                        .controlSize(.small)
                        .help("Stop where it is and keep what it has")
                } else {
                    Button("Render  ⌘↩", action: model.render)
                        .controlSize(.small)
                }
                Button { model.toggleRenderDrawer() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .help("Hide the render")
                .accessibilityLabel("Hide the render")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            // The second row: what's in the picture, and where it went.
            HStack(spacing: 12) {
                Toggle("Floor", isOn: $model.renderFloor)
                    .toggleStyle(.checkbox)
                    .font(.aeSmall)
                    .help("A floor under everything, for shadows to fall on")
                if model.renderEngine == .quick {
                    Toggle("Shadows", isOn: $model.renderShadows)
                        .toggleStyle(.checkbox)
                        .font(.aeSmall)
                } else {
                    Toggle("Denoise", isOn: $model.renderDenoise)
                        .toggleStyle(.checkbox)
                        .font(.aeSmall)
                        .help("Smooth the grain where surfaces agree, keeping their edges, so fewer samples do")
                }
                Toggle("Clear background", isOn: $model.renderTransparent)
                    .toggleStyle(.checkbox)
                    .font(.aeSmall)
                    .help("Leave the background clear, for the picture to sit on another")
                Spacer()
                if model.lastRender != nil {
                    Button("Show in Finder", action: model.revealRender).controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            if let last = model.lastRender {
                HStack(spacing: 10) {
                    picture(last.beauty, title: "\(document.name) Render", version: last.versions?.beauty, clear: model.renderTransparent)
                    picture(last.depth, title: "\(document.name) Depth", version: last.versions?.depth, clear: false)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            } else {
                Text("Render draws the scene from the camera, larger and cleaner than the view, and its depth: near white, far black. Both are written into renders/ beside the scene and published as the project’s assets, so a flow’s Load Image or a canvas follows each new render.")
                    .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
        }
        .aeGlass(.floating, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Render")
    }

    private func picture(_ image: CGImage, title: String, version: Int?, clear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .background(clear ? AnyView(Checks()) : AnyView(Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
                .accessibilityLabel(title)
            HStack(spacing: 6) {
                Text(title).font(.aeSmall).foregroundStyle(Color.ink)
                Text(verbatim: version.map { "v\($0) · \(image.width) × \(image.height)" } ?? "\(image.width) × \(image.height)").font(.aeMono).foregroundStyle(Color.ink2)
            }
        }
    }
}

/// A checkerboard, under a picture with a clear background.
private struct Checks: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: cell) {
                for x in stride(from: 0, to: size.width, by: cell) where (Int(x / cell) + Int(y / cell)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color.white.opacity(0.06)))
                }
            }
        }
    }
}
