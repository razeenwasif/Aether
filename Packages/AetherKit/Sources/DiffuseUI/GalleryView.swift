import AetherDesign
import AppKit
import DiffuseBridge
import DiffuseCore
import ImageIO
import SwiftUI

/// The stage's switch between the flow's graph and the gallery.
struct StageSwitch: View {
    @Bindable var model: DiffuseWorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            segment("Graph", .graph)
            segment("Gallery", .gallery)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
        .help("Graph or Gallery (⇧⌘G)")
    }

    private func segment(_ title: String, _ stage: DiffuseWorkspaceModel.Stage) -> some View {
        let on = model.stage == stage
        return Button { model.show(stage) } label: {
            Text(title)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.obsidian0 : Color.ink)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.runFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The pictures runs have made, newest first, filtered by flow; or, while
/// the gallery is shut, a way to open it.
struct GalleryStage: View {
    @Bindable var model: DiffuseWorkspaceModel
    let leftInset: CGFloat
    let rightInset: CGFloat

    private var gallery: Gallery { model.gallery }
    private var outputsMade: Int { model.queue.runs.reduce(0) { $0 + $1.outputs.count } }

    var body: some View {
        Group {
            if model.galleryLocked {
                locked
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let target = model.pickingInput {
                        picking(target)
                    }
                    head
                    if gallery.shown.isEmpty {
                        empty
                    } else {
                        grid
                    }
                }
                .padding(.top, 54)
                .padding(.leading, leftInset + 16)
                .padding(.trailing, rightInset + 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.obsidian0)
        .task(id: outputsMade) { await model.refreshGallery() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let png = urls.first(where: { SealedFiles.plain($0).pathExtension.lowercased() == "png" }) else { return false }
            Task { await model.openGraph(of: png) }
            return true
        }
        .confirmationDialog(trashTitle, isPresented: $model.askingTrash) {
            Button("Move to Trash", role: .destructive, action: model.trashPicked)
        } message: {
            Text("You can take them back out of the Trash in Finder.")
        }
    }

    private var trashTitle: String {
        gallery.picked.count == 1 ? "Move this image to the Trash?" : "Move \(gallery.picked.count) images to the Trash?"
    }

    private var locked: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 22)).foregroundStyle(Color.ink2)
            Text("The Gallery is locked.").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.inkHi)
            Text("Unlock it with Touch ID or your password to see every image Diffuse has made. It locks again when you leave it.")
                .font(.system(size: 12)).foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(model.unlocking ? "Waiting for you…" : "Unlock the Gallery") { Task { await model.unlockGallery() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.runFill)
                .foregroundStyle(Color.obsidian0)
                .disabled(model.unlocking)
                .padding(.top, 4)
            if let said = model.unlockSaid {
                Text(said).font(.system(size: 11.5)).foregroundStyle(Color.coral).multilineTextAlignment(.center).frame(maxWidth: 340)
            }
        }
        .padding(28)
        .aeGlass(.floating, radius: Radius.floating)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, leftInset)
        .padding(.trailing, rightInset)
    }

    /// Waiting to give a Load Image its picture.
    private func picking(_ target: DiffuseWorkspaceModel.PictureTarget) -> some View {
        let title = model.editor?.flow.node(target.node).flatMap { model.editor?.library.catalogue.node($0.type)?.title } ?? "Load Image"
        return HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(Color.ice)
            Text("Choose a picture for \(title) \(target.node), then Use as its picture, or double-click it.")
                .font(.system(size: 12)).foregroundStyle(Color.inkHi)
            Spacer()
            Button("Cancel", action: model.cancelPicking).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.ice.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.ice.opacity(0.3)))
    }

    private var head: some View {
        HStack(spacing: 10) {
            Text("Show").font(.system(size: 12)).foregroundStyle(Color.ink2)
            Picker("Show", selection: Binding(get: { gallery.filter }, set: { gallery.filter = $0 })) {
                Text("every flow’s").tag(String?.none)
                if !gallery.flows.isEmpty { Divider() }
                ForEach(gallery.flows, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Text("\(gallery.shown.count) \(gallery.shown.count == 1 ? "image" : "images"), newest first")
                .font(.system(size: 11.5)).foregroundStyle(Color.ink3)
            Spacer()
            if gallery.sealedCount > 0 && model.sealKey == nil {
                if let said = model.sealSaid {
                    Text(said).font(.system(size: 11.5)).foregroundStyle(Color.coral).lineLimit(1).truncationMode(.tail)
                }
                Button { Task { await model.unlockSealed() } } label: {
                    Label(model.sealUnlocking ? "Waiting for you…" : "Unlock \(gallery.sealedCount) sealed", systemImage: "lock.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.sealUnlocking)
                .help("Proton sealed these. Unlock with Touch ID or your password to see them.")
            }
            IconButton("arrow.clockwise", label: "Look again") { Task { await model.refreshGallery() } }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(gallery.scanned ? "No outputs yet." : "Looking…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.inkHi)
            if gallery.scanned {
                Text("A flow’s Save Image writes its pictures into outputs/<flow>/ beside it; they show here.")
                    .font(.system(size: 12)).foregroundStyle(Color.ink2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(gallery.shown) { picture in
                    GalleryTile(model: model, picture: picture, isPicked: gallery.picked.contains(picture.url))
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }
}

/// One picture: its thumbnail, its name and its seed.
private struct GalleryTile: View {
    @Bindable var model: DiffuseWorkspaceModel
    let picture: GalleryPicture
    let isPicked: Bool
    @State private var hovering = false
    @State private var seed: UInt64?

    var body: some View {
        Button { model.gallery.pick(picture.url, adding: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Thumbnail(url: picture.url, side: 360, key: model.sealKey)
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)
                    .background(Color.obsidian1)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if picture.isSealed && model.sealKey != nil {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.inkHi)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                                .padding(6)
                                .help("Sealed with Proton’s key")
                        }
                    }
                HStack(spacing: 6) {
                    Text(picture.name).font(.aeMono).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let seed { Text(verbatim: "\(seed)").font(.aeMono).foregroundStyle(Color.ink3).lineLimit(1) }
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hovering || isPicked ? Color.raise1 : .clear))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isPicked ? Color.ice.opacity(0.75) : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Task {
                if model.pickingInput != nil { await model.useAsInput(picture) } else { await model.openGraph(of: picture.url) }
            }
        })
        .task(id: HeadRequest(url: picture.url, unlocked: model.sealKey != nil)) {
            seed = await model.gallery.head(for: picture.url)?.made?.seed
        }
        .accessibilityLabel(picture.isSealed ? "\(picture.name), sealed" : picture.name)
        .accessibilityValue(seed.map { "Seed \($0)" } ?? "")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityAction(named: "Open its graph") { Task { await model.openGraph(of: picture.url) } }
        .draggable(picture.url)
        .contextMenu {
            Button("Open Its Graph") { Task { await model.openGraph(of: picture.url) } }
            Button("Send to Canvas") { Task { await model.sendToCanvas(picture) } }
            Button("Show in Finder") { model.showInFinder([picture.url]) }
            Button("Copy Its Path") { model.copyPath(picture.url) }
        }
    }
}

// MARK: - The chosen picture

/// What made the chosen picture, large, with what can be done with it.
struct GalleryInspector: View {
    @Bindable var model: DiffuseWorkspaceModel
    @State private var head: PictureHead?

    private var gallery: Gallery { model.gallery }

    var body: some View {
        Group {
            if model.galleryLocked {
                VStack(spacing: 0) {
                    InspectorHeader(symbol: "lock.fill", title: "Gallery", subtitle: "Locked")
                    Spacer()
                }
            } else if gallery.picked.count > 1 {
                many
            } else if let picture = gallery.chosenPicture {
                one(picture)
            } else {
                nothing
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass()
        .task(id: HeadRequest(url: gallery.chosen, unlocked: model.sealKey != nil)) {
            head = nil
            if let url = gallery.chosen { head = await gallery.head(for: url) }
        }
    }

    private var nothing: some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: "photo.on.rectangle.angled", title: "Gallery",
                            subtitle: "\(gallery.pictures.count) \(gallery.pictures.count == 1 ? "image" : "images")")
            PanelSection("Chosen") {
                Text("Choose an image to see what made it. ⌘-click chooses more; ⌫ moves them to the Trash.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            PanelSection("Lock") {
                Toggle(isOn: $model.galleryLockOn) {
                    Text("Ask for Touch ID or your password each time the Gallery is shown")
                        .font(.system(size: 11.5)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            PanelSection("Folders") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.galleryRoots, id: \.self) { root in
                        Text(verbatim: root.appending(path: "outputs").path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.aeMono).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var many: some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: "square.stack", title: "\(gallery.picked.count) images", subtitle: "⌘-click adds an image or takes it away")
            PanelSection("Actions") {
                VStack(alignment: .leading, spacing: 6) {
                    ActionButton("Show in Finder", symbol: "folder") { model.showInFinder(Array(gallery.picked)) }
                    ActionButton("Move \(gallery.picked.count) to the Trash", symbol: "trash", role: .destructive, action: model.askToTrash)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func one(_ picture: GalleryPicture) -> some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: picture.isSealed ? "lock.doc" : "photo", title: picture.name, subtitle: subtitle(picture))
            ScrollView {
                VStack(spacing: 0) {
                    Thumbnail(url: picture.url, side: 900, key: model.sealKey, fit: true)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    if picture.isSealed && model.sealKey == nil {
                        PanelSection("Sealed") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Proton sealed this picture. Unlock with Touch ID or your password to see it and what made it.")
                                    .font(.system(size: 11.5)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                                ActionButton(model.sealUnlocking ? "Waiting for you…" : "Unlock sealed files", symbol: "lock.open", prominent: true) {
                                    Task { await model.unlockSealed() }
                                }
                                .disabled(model.sealUnlocking)
                                if let said = model.sealSaid {
                                    Text(said).font(.system(size: 11.5)).foregroundStyle(Color.coral).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else if let made = head?.made {
                        PanelSection("Made with") { MadeRows(made: made) }
                    } else if head != nil {
                        PanelSection("Made with") {
                            Text("This PNG holds no graph: it was not made by a flow, or not by forge.")
                                .font(.system(size: 11.5)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    PanelSection("Actions") { actions(picture) }
                }
            }
        }
    }

    private func subtitle(_ picture: GalleryPicture) -> String {
        let size = head.map { "\($0.width) × \($0.height) · " } ?? ""
        let sealed = picture.isSealed ? " · sealed" : ""
        return size + picture.modified.formatted(date: .abbreviated, time: .shortened) + sealed
    }

    private func actions(_ picture: GalleryPicture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.pickingInput != nil {
                ActionButton("Use as Load Image’s picture", symbol: "square.and.arrow.down.on.square", prominent: true) {
                    Task { await model.useAsInput(picture) }
                }
            }
            if head?.graphJSON != nil {
                ActionButton("Open its graph", symbol: "point.3.connected.trianglepath.dotted", prominent: model.pickingInput == nil) {
                    Task { await model.openGraph(of: picture.url) }
                }
                .help("The graph forge wrote into it, as a new flow")
            }
            if let flow = model.flowFile(for: picture) {
                ActionButton("Open \(flow.deletingPathExtension().deletingPathExtension().lastPathComponent)", symbol: "doc") {
                    model.openFlow(at: flow)
                }
            }
            if model.pickingInput == nil {
                ActionButton("Use as input", symbol: "square.and.arrow.down.on.square") {
                    Task { await model.useAsInput(picture) }
                }
                .disabled(model.editor == nil)
                .help(model.editor == nil ? "Open a flow to use it in" : "Give the flow’s Load Image this picture, or add a Load Image with it")
            }
            ActionButton("Send to Canvas", symbol: "paintbrush.pointed") {
                Task { await model.sendToCanvas(picture) }
            }
            .help(picture.isSealed ? "A new canvas of it, not written until you save it: canvases are saved plain" : "A new canvas of it, in Canvases")
            ActionButton("Send to Game", symbol: "gamecontroller") {}
                .disabled(true)
                .help("The Game workspace isn't built yet")
            ActionButton("Show in Finder", symbol: "folder") { model.showInFinder([picture.url]) }
            ActionButton("Copy its path", symbol: "doc.on.doc") { model.copyPath(picture.url) }
            ActionButton("Move to Trash", symbol: "trash", role: .destructive, action: model.askToTrash)
        }
    }
}

/// A picture's seed, settings and prompts, as rows.
private struct MadeRows: View {
    let made: Made

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Seed", made.seed.map { "\($0)" }, mono: true)
            row("Steps", made.steps.map { "\($0)" }, mono: true)
            row("CFG", made.cfg.map { trimmed($0) }, mono: true)
            row("Sampler", [made.sampler, made.scheduler].compactMap { $0 }.joined(separator: " · "))
            row("Denoise", made.denoise.map { trimmed($0) }, mono: true)
            row("Model", made.checkpoint.map { $0.replacingOccurrences(of: ".safetensors", with: "") })
            prompt("Prompt", made.prompt)
            prompt("Negative", made.negative)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        if let value, !value.isEmpty {
            LabeledRow(label) {
                Text(verbatim: value)
                    .font(mono ? .aeMono : .system(size: 11.5))
                    .foregroundStyle(Color.inkHi)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func prompt(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                Text(verbatim: value)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.inkHi)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
            }
        }
    }

    private func trimmed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// A full-width button in an inspector's list of actions.
private struct ActionButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        if prominent { return .obsidian0 }
        return role == .destructive ? .coral : .inkHi
    }

    private var fill: Color {
        if prominent { return hovering ? .white : .runFill }
        return Color.white.opacity(hovering && isEnabled ? 0.09 : 0.05)
    }
}

// MARK: - Thumbnails

/// A picture drawn from a thumbnail ImageIO makes, never the whole file.
struct Thumbnail: View {
    let url: URL
    let side: Int
    /// Proton's key, for a sealed picture; without it one shows locked.
    var key: SealKey?
    var fit = false
    @State private var image: CGImage?

    private var isSealed: Bool { url.lastPathComponent.hasSuffix(SealedFiles.suffix) }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: fit ? nil : .infinity)
                    .clipped()
            } else {
                Rectangle().fill(Color.obsidian1)
                    .aspectRatio(fit ? 16 / 10 : nil, contentMode: .fit)
                    .overlay {
                        if isSealed && key == nil {
                            VStack(spacing: 6) {
                                Image(systemName: "lock.fill").font(.system(size: 18))
                                Text("Sealed").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Color.ink3)
                        }
                    }
            }
        }
        .task(id: HeadRequest(url: url, unlocked: key != nil)) {
            image = await Thumbnails.shared.image(url, side: side, key: key)
        }
    }
}

/// What a picture's head or thumbnail is read again for: another picture,
/// or sealed files unlocked or locked.
struct HeadRequest: Hashable {
    let url: URL?
    let unlocked: Bool
}

/// Thumbnails made once a gallery opening, let go when it shuts.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var kept: [String: Kept] = [:]

    private struct Kept: @unchecked Sendable { let image: CGImage }

    /// A thumbnail of `url`. A sealed picture is opened with `key`, in
    /// memory only; without it, `nil`.
    func image(_ url: URL, side: Int, key sealKey: SealKey? = nil) async -> CGImage? {
        let sealed = url.lastPathComponent.hasSuffix(SealedFiles.suffix)
        guard !sealed || sealKey != nil else { return nil }
        let key = "\(side):\(url.path)"
        if let hit = kept[key] { return hit.image }
        let result = await Task.detached(priority: .userInitiated) { () -> Kept? in
            let source: CGImageSource?
            if sealed {
                source = (try? readFile(path: url.path, key: sealKey)).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            } else {
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            }
            guard let source,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: side,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary)
            else { return nil }
            return Kept(image: image)
        }.value
        kept[key] = result
        return result?.image
    }

    func forget() { kept = [:] }

    /// Let go of one picture's thumbnails, at every size: it was written again.
    func forget(_ url: URL) { kept = kept.filter { !$0.key.hasSuffix(":\(url.path)") } }

    /// Let go of every sealed picture's thumbnail: sealed files locked.
    func forgetSealed() { kept = kept.filter { !$0.key.hasSuffix(SealedFiles.suffix) } }
}
