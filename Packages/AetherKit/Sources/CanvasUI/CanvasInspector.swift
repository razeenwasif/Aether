import AetherDesign
import AetherGraph
import CanvasCore
import SwiftUI

/// The colour drawn with, the tool's settings and the layers.
struct CanvasInspector: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    LinkSection(model: model)
                    ColourSection(model: model)
                    PaletteSection(model: model)
                    ToolSection(model: model)
                    MakeSection(model: model)
                    AnimationSection(model: model, document: document)
                }
            }
            .frame(maxHeight: 620)
            .fixedSize(horizontal: false, vertical: true)
            LayersSection(model: model, document: document)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }
}

// MARK: - Links

/// Where the layer comes from when it follows another workspace's asset,
/// with a live dot (inspector rule 5), and who uses the canvas when it is
/// an asset itself.
private struct LinkSection: View {
    @Bindable var model: CanvasWorkspaceModel

    var body: some View {
        if let project = model.project, let layer = model.currentLayer, let link = model.link(of: layer), let asset = project.asset(link.asset) {
            // What the layer shows, which undo may have put back behind.
            let shown = link.shown ?? project.version(for: link)?.number ?? 0
            let newest = asset.newest?.number ?? 0
            PanelSection("Linked") {
                HStack(spacing: 7) {
                    Circle().fill(link.pinned == nil ? Color.live : Color.ink3).frame(width: 7, height: 7)
                    Text(asset.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                    Text(asset.source.title).font(.aeSmall).foregroundStyle(Color.ink2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(asset.name), from \(asset.source.title), \(link.pinned == nil ? "live" : "kept")")
                Text(link.pinned != nil
                    ? "Keeps v\(shown) of \(asset.versions.count), whatever \(asset.source.title) makes next."
                    : shown < newest
                    ? "Live, but shows v\(shown) of \(asset.versions.count): undo put it back. The next version replaces it."
                    : "Live: shows v\(shown) of \(asset.versions.count). A newer picture from \(asset.source.title) replaces this layer.")
                    .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                if link.pinned == nil, shown < newest {
                    Button("Take v\(newest)") { model.takeNewest(link) }
                        .controlSize(.small)
                        .help("Show the newest version again")
                }
                Picker("Version", selection: Binding(get: { link.pinned ?? 0 }, set: { model.keep($0 == 0 ? nil : $0, for: link) })) {
                    Text("The newest").tag(0)
                    ForEach(asset.versions.reversed(), id: \.number) { version in
                        Text("v\(version.number)" + (version.note.map { " · \($0)" } ?? "")).tag(version.number)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .help("Follow the newest version, or keep one")
                HStack(spacing: 8) {
                    Button("Unlink") { model.unlink(link) }
                        .help("Keep what the layer shows, to paint on, and stop following")
                    Button("Show the Source") { model.showSource?(asset) }
                        .help("Open what makes \(asset.name) in \(asset.source.title)")
                }
                .controlSize(.small)
            }
        }
        let users = model.usedBy
        if let project = model.project, !users.isEmpty {
            PanelSection("Used elsewhere") {
                ForEach(users) { link in
                    HStack(spacing: 7) {
                        Circle().fill(link.pinned == nil ? Color.live : Color.ink3).frame(width: 7, height: 7)
                        Text(project.url(of: link.document).deletingPathExtension().deletingPathExtension().lastPathComponent).font(.aeBody).foregroundStyle(Color.inkHi).lineLimit(1)
                        Text(link.consumer.title).font(.aeSmall).foregroundStyle(Color.ink2)
                    }
                }
                Text("Saving publishes a new version to each.").font(.aeSmall).foregroundStyle(Color.ink2)
            }
        }
    }
}

// MARK: - Colour

private struct ColourSection: View {
    @Bindable var model: CanvasWorkspaceModel
    @State private var hex = ""
    @FocusState private var typing: Bool

    var body: some View {
        PanelSection("Colour") {
            HStack(spacing: 10) {
                ColorWell(model: model)
                TextField("Hex", text: $hex)
                    .textFieldStyle(.plain)
                    .font(.aeMono)
                    .foregroundStyle(Color.ink)
                    .frame(width: 96)
                    .focused($typing)
                    .onSubmit {
                        model.setColor(hex: hex)
                        hex = model.color.hex
                    }
                    .help("Type a hex code: #rrggbb, or #rrggbbaa")
                    .accessibilityLabel("Colour, as hex")
                Spacer()
            }
            if !model.recent.isEmpty {
                Text("Lately").font(.aeSmall).foregroundStyle(Color.ink3)
                Swatches(colors: model.recent, chosen: { $0 == model.color }, help: { "\($0.hex) — used lately" }) { model.color = model.recent[$0] }
            }
        }
        .onAppear { hex = model.color.hex }
        .onChange(of: model.color) { if !typing { hex = model.color.hex } }
        .onChange(of: typing) { if !typing { hex = model.color.hex } }
    }
}

/// Small squares of colour, eleven to a row.
private struct Swatches: View {
    let colors: [RGBA]
    let chosen: (RGBA) -> Bool
    let help: (RGBA) -> String
    var twice: ((Int) -> Void)?
    let pick: (Int) -> Void

    init(colors: [RGBA], chosen: @escaping (RGBA) -> Bool, help: @escaping (RGBA) -> String, twice: ((Int) -> Void)? = nil, pick: @escaping (Int) -> Void) {
        self.colors = colors
        self.chosen = chosen
        self.help = help
        self.twice = twice
        self.pick = pick
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 11), alignment: .leading, spacing: 4) {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                Button { pick(i) } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.color)
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(chosen(color) ? Color.inkHi : Color.white.opacity(0.12), lineWidth: chosen(color) ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { twice?(i) })
                .help(help(color))
                .accessibilityLabel(color.hex)
            }
        }
    }
}

// MARK: - The palette

/// The canvas's palette, as Proton's: a swatch to draw with, the colour
/// drawn with added, a ramp of it, and a swatch recoloured everywhere it is.
private struct PaletteSection: View {
    @Bindable var model: CanvasWorkspaceModel

    var body: some View {
        let palette = model.palette
        PanelSection("Palette") {
            if palette.isEmpty {
                Text("No palette yet.").font(.aeSmall).foregroundStyle(Color.ink3)
            } else {
                Swatches(colors: palette, chosen: { $0 == model.color },
                         help: { "\($0.hex) — click to draw with it, double-click to change it everywhere it is" },
                         twice: { i in
                             model.chooseSwatch(i)
                             ColorPanelLink.shared.open(for: model)
                         },
                         pick: { model.chooseSwatch($0) })
            }
            HStack(spacing: 6) {
                if model.canRecolour, let i = model.swatch {
                    Button("Recolour") { model.recolourSwatch() }
                        .buttonStyle(.borderedProminent)
                        .help("\(palette[i].hex) becomes \(model.color.hex), the swatch and every pixel of it, as one edit")
                }
                Button("Add") { model.addToPalette() }
                    .disabled(palette.contains(model.color))
                    .help("Add \(model.color.hex) to the palette")
                Button("Ramp") { model.addRamp() }
                    .help("Five steps of \(model.color.hex), darker and lighter, the hue turning as a painter’s shading does")
                if palette.contains(model.color) {
                    Button("Remove") { model.removeFromPalette() }
                        .help("Take \(model.color.hex) out of the palette")
                }
            }
            .controlSize(.small)
            Text(model.canRecolour ? "Recolour changes the chosen swatch, and every pixel of it, to the colour drawn with." : "Double-click a swatch to change its colour, then Recolour changes every pixel of it as one edit.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The tool

private struct ToolSection: View {
    @Bindable var model: CanvasWorkspaceModel

    var body: some View {
        if let moving = model.moving, moving.free {
            transformRows
        } else {
            toolRows
        }
    }

    /// ⌘T's: keep it, leave it, mirror it.
    private var transformRows: some View {
        PanelSection("Transform") {
            hint("Drag inside to move it, a handle to scale it, outside to turn it. ⇧ scales it freely and turns it by 15°.")
            HStack(spacing: 6) {
                Button("Keep it") { model.finishTransform() }
                    .buttonStyle(.borderedProminent)
                    .help("↩")
                Button("Leave it") { model.leaveTransform() }
                    .help("⎋")
                Spacer()
                Button { model.mirrorMoving(across: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Mirror it across")
                    .accessibilityLabel("Mirror it across")
                Button { model.mirrorMoving(across: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Mirror it down")
                    .accessibilityLabel("Mirror it down")
            }
            .controlSize(.small)
        }
    }

    private var toolRows: some View {
        PanelSection(model.tool.title) {
            switch model.tool {
            case .select:
                HStack(spacing: 8) {
                    Text("Shape").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 92, alignment: .leading)
                    Picker("Shape", selection: $model.selectShape) {
                        ForEach(CanvasSelectShape.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                selectRows
            case .wand:
                slider("Tolerance", value: $model.wandTolerance, range: 0...255, shown: "\(model.wandTolerance)")
                Toggle("Only what touches it", isOn: $model.wandContiguous).toggleStyle(.checkbox).font(.aeBody)
                Toggle("Across corners too", isOn: $model.wandDiagonal).toggleStyle(.checkbox).font(.aeBody)
                    .disabled(!model.wandContiguous)
                selectRows
            case .move:
                hint("Drag to move what is selected — all of the layer when nothing is. ⌘T scales and turns it.")
            case .pick:
                hint("Click the canvas to take its colour. ⌥-click does it with any tool.")
            case .fill:
                slider("Tolerance", value: $model.tolerance, range: 0...255, shown: "\(model.tolerance)")
                Toggle("Only what touches", isOn: $model.contiguous).toggleStyle(.checkbox).font(.aeBody)
            case .line, .rect, .ellipse:
                tipRows
                if model.tool != .line {
                    Toggle("Filled", isOn: $model.shapeFilled).toggleStyle(.checkbox).font(.aeBody)
                }
                hint("⇧ makes it a square, a circle, or a line at 45°.")
            default:
                if model.usesTip {
                    tipRows
                    if model.tool == .pencil {
                        Toggle("Pixel-perfect", isOn: $model.pixelPerfect).toggleStyle(.checkbox).font(.aeBody)
                            .help("Takes the corners out of a line’s steps (p)")
                    }
                } else {
                    brushRows
                }
            }
        }
    }

    /// How a selection joins what is selected, and its feather.
    @ViewBuilder private var selectRows: some View {
        HStack(spacing: 8) {
            Text("Joins").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 92, alignment: .leading)
            Picker("Joins", selection: $model.selectMode) {
                ForEach(CanvasSelectMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        slider("Feather", value: $model.feather, range: 0...250, shown: "\(model.feather) px")
        hint("⌘A selects all, ⌘D nothing, ⇧⌘I the rest. ⌫ clears it; ⌘C, ⌘X and ⌘V copy, cut and paste.")
    }

    @ViewBuilder private var tipRows: some View {
        slider("Size", value: $model.tip.size, range: 1...64, shown: "\(model.tip.size) px")
        Toggle("Round", isOn: $model.tip.round).toggleStyle(.checkbox).font(.aeBody)
        Toggle("Mirror across the middle (m)", isOn: $model.mirrorAcross).toggleStyle(.checkbox).font(.aeBody)
        Toggle("Mirror down the middle (⇧M)", isOn: $model.mirrorDown).toggleStyle(.checkbox).font(.aeBody)
    }

    @ViewBuilder private var brushRows: some View {
        slider("Size", value: sizeBinding, range: 0...1, shown: "\(model.brush.size) px")
        slider("Hardness", value: $model.brush.hardness, range: 0...100, shown: "\(model.brush.hardness)%")
        slider("Flow", value: $model.brush.flow, range: 1...255, shown: "\(percent(model.brush.flow))%")
        slider("Opacity", value: $model.brush.opacity, range: 1...255, shown: "\(percent(model.brush.opacity))%")
        slider("Spacing", value: $model.brush.spacing, range: 1...200, shown: "\(model.brush.spacing)%")
        slider("Pressure → size", value: $model.brush.sizePressure, range: 0...100, shown: "\(model.brush.sizePressure)%")
    }

    /// The brush's size along a curve, so small sizes get room: 1 to 1000.
    private var sizeBinding: Binding<Double> {
        Binding(get: { log(Double(model.brush.size)) / log(1000) },
                set: { model.brush.size = UInt32(max(1, min(1000, pow(1000, $0).rounded()))) })
    }

    private func percent(_ v: UInt8) -> Int { Int((Double(v) / 255 * 100).rounded()) }

    private func hint(_ text: String) -> some View {
        Text(text).font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private func slider<V: BinaryInteger>(_ label: String, value: Binding<V>, range: ClosedRange<Double>, shown: String) -> some View {
        slider(label, value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0.rounded()) }), range: range, shown: shown)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, shown: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
            Text(shown).font(.aeMono).foregroundStyle(Color.ink).frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Animation

/// Proton's animation fields: the frame's time, for every frame too; onion
/// skin's reach and tint; and the tags — each a name over a run of frames,
/// played on, back, or to the end and back.
private struct AnimationSection: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument

    var body: some View {
        let n = model.frameCount
        let ms = document.state.frames[safe: model.frame] ?? 100
        PanelSection("Animation") {
            Text(verbatim: "Frame \(model.frame + 1) of \(n), shown \(ms) ms." + (n > 1 ? "" : " ＋ or ⇧N under the picture adds a frame."))
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            if n > 1 {
                Button("Every frame \(ms) ms") { model.setDurationForAll() }
                    .controlSize(.small)
                    .help("Every frame shown as long as this one")
            }
            Toggle("Onion skin (⇧O)", isOn: $model.onionOn).toggleStyle(.checkbox).font(.aeBody)
            reach("Frames before", $model.onionBefore)
            reach("Frames after", $model.onionAfter)
            Toggle("Tinted — before red, after blue", isOn: $model.onionTint).toggleStyle(.checkbox).font(.aeBody)
            if n > 1 {
                Text("Tags").font(.aeSmall).foregroundStyle(Color.ink3).padding(.top, 4)
                ForEach(Array(model.tags.enumerated()), id: \.offset) { i, tag in
                    TagRow(model: model, index: i, tag: tag, frames: n)
                }
                Button("＋ A tag here") { model.addTag() }
                    .controlSize(.small)
                    .help("A tag over this frame, to widen")
            }
        }
    }

    private func reach(_ label: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 92, alignment: .leading)
            Picker(label, selection: value) {
                ForEach(0...3, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 64)
            .disabled(!model.onionOn)
        }
    }
}

/// A tag: its colour, its name, its first and last frames, how it plays.
private struct TagRow: View {
    @Bindable var model: CanvasWorkspaceModel
    let index: Int
    let tag: CanvasTag
    let frames: Int
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(CanvasTimeline.tagColours[index % CanvasTimeline.tagColours.count]).frame(width: 8, height: 8)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { model.editTag(index, name: name) }
                    .accessibilityLabel("Its name")
                frameField(Int(tag.from) + 1, label: "Its first frame") { model.editTag(index, from: $0 - 1) }
                Text(verbatim: "–").foregroundStyle(Color.ink2)
                frameField(Int(tag.to) + 1, label: "Its last frame") { model.editTag(index, to: $0 - 1) }
                Button { model.removeTag(index) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink2)
                    .help("Take the tag away")
                    .accessibilityLabel("Take the tag away")
            }
            Picker("How it plays", selection: Binding(get: { tag.direction }, set: { model.editTag(index, direction: $0) })) {
                ForEach(CanvasDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .padding(.leading, 14)
        }
        .onAppear { name = tag.name }
        .onChange(of: tag.name) { name = tag.name }
    }

    private func frameField(_ value: Int, label: String, set: @escaping (Int) -> Void) -> some View {
        TextField(label, value: Binding(get: { value }, set: { set(min(frames, max(1, $0))) }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 38)
            .accessibilityLabel(label)
    }
}

// MARK: - Layers

private struct LayersSection: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument
    @State private var renaming: UInt32?
    @State private var newName = ""
    @State private var opacity: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("Layers").font(.aeLabel).foregroundStyle(Color.ink2)
                Spacer()
                small("plus", "Add a layer above this one", action: model.addLayer)
                small("minus", "Remove this layer", action: model.removeLayer)
                    .disabled(document.state.layers.count < 2)
                small("arrow.up", "Move it up") { model.moveLayer(up: true) }
                    .disabled(document.state.layers.last?.id == model.currentLayer?.id)
                small("arrow.down", "Move it down") { model.moveLayer(up: false) }
                    .disabled(document.state.layers.first?.id == model.currentLayer?.id)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(document.state.layers.reversed()) { layer in
                        row(layer)
                    }
                }
                .padding(.horizontal, 6)
            }

            if let current = model.currentLayer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Opacity").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 52, alignment: .leading)
                        Slider(value: Binding(get: { opacity ?? Double(current.opacity) }, set: { opacity = $0 }), in: 0...255) { editing in
                            if !editing, let value = opacity {
                                model.setLayer(current.id, opacity: UInt8(value.rounded()), label: "Opacity")
                                opacity = nil
                            }
                        }
                        .controlSize(.small)
                        Text("\(Int(((opacity ?? Double(current.opacity)) / 255 * 100).rounded()))%").font(.aeMono).foregroundStyle(Color.ink).frame(width: 40, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text("Blend").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 52, alignment: .leading)
                        Picker("Blend", selection: Binding(get: { current.blend }, set: { model.setLayer(current.id, blend: $0, label: "Blend") })) {
                            ForEach(CanvasBlend.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    Toggle("Lock what’s clear", isOn: Binding(get: { current.alphaLock }, set: { model.setLayer(current.id, alphaLock: $0, label: $0 ? "Lock what’s clear" : "Unlock what’s clear") }))
                        .toggleStyle(.checkbox).font(.aeBody)
                        .help("Draw only where the layer already has something: shading inside a line")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ layer: CanvasLayer) -> some View {
        let isCurrent = layer.id == model.currentLayer?.id
        return HStack(spacing: 6) {
            Button {
                model.setLayer(layer.id, hidden: !layer.hidden, label: layer.hidden ? "Show \(layer.name)" : "Hide \(layer.name)")
            } label: {
                Image(systemName: layer.hidden ? "eye.slash" : "eye").font(.system(size: 11)).frame(width: 20, height: 20)
                    .foregroundStyle(layer.hidden ? Color.ink3 : Color.ink)
            }
            .buttonStyle(.plain)
            .help(layer.hidden ? "Show it" : "Hide it")
            .accessibilityLabel(layer.hidden ? "Show \(layer.name)" : "Hide \(layer.name)")

            if renaming == layer.id {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.aeBody)
                    .onSubmit { finishRenaming(layer) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(layer.name).font(isCurrent ? .aeBodyStrong : .aeBody).foregroundStyle(layer.hidden ? Color.ink3 : Color.inkHi).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        newName = layer.name
                        renaming = layer.id
                    }
                    .onTapGesture { model.layer = layer.id }
            }
            if layer.opacity < 255 {
                Text("\(Int((Double(layer.opacity) / 255 * 100).rounded()))%").font(.aeMono).foregroundStyle(Color.ink3)
            }
            if let link = model.link(of: layer) {
                Circle().fill(link.pinned == nil ? Color.live : Color.ink3).frame(width: 6, height: 6)
                    .help(link.pinned == nil ? "Follows an asset: live" : "Follows an asset: a version kept")
                    .accessibilityLabel(link.pinned == nil ? "Linked, live" : "Linked, a version kept")
            }
            Button {
                model.setLayer(layer.id, locked: !layer.locked, label: layer.locked ? "Unlock \(layer.name)" : "Lock \(layer.name)")
            } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open").font(.system(size: 10)).frame(width: 20, height: 20)
                    .foregroundStyle(layer.locked ? Color.ink : Color.ink3.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(layer.locked ? "Unlock it" : "Lock it: it can’t be drawn on")
            .accessibilityLabel(layer.locked ? "Unlock \(layer.name)" : "Lock \(layer.name)")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Radius.button).fill(isCurrent ? Color.white.opacity(0.09) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.layer = layer.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func finishRenaming(_ layer: CanvasLayer) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != layer.name else { return }
        model.setLayer(layer.id, name: name, label: "Rename")
    }

    private func small(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
        .help(label)
        .accessibilityLabel(label)
    }
}
