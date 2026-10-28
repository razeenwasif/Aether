import AetherDesign
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
                    ColourSection(model: model, document: document)
                    ToolSection(model: model)
                }
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            LayersSection(model: model, document: document)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }
}

// MARK: - Colour

private struct ColourSection: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument

    var body: some View {
        PanelSection("Colour") {
            HStack(spacing: 10) {
                ColorWell(model: model)
                Text(model.color.hex).font(.aeMono).foregroundStyle(Color.ink).textSelection(.enabled)
                Spacer()
            }
            if !document.state.palette.isEmpty {
                swatches(document.state.palette.map(RGBA.init), help: "The canvas’s palette")
            }
            if !model.recent.isEmpty {
                Text("Lately").font(.aeSmall).foregroundStyle(Color.ink3)
                swatches(model.recent, help: "Used lately")
            }
        }
    }

    private func swatches(_ colors: [RGBA], help: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 11), alignment: .leading, spacing: 4) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button {
                    model.color = color
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.color)
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color == model.color ? Color.inkHi : Color.white.opacity(0.12), lineWidth: color == model.color ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .help("\(color.hex) — \(help)")
                .accessibilityLabel(color.hex)
            }
        }
    }
}

// MARK: - The tool

private struct ToolSection: View {
    @Bindable var model: CanvasWorkspaceModel

    var body: some View {
        PanelSection(model.tool.title) {
            switch model.tool {
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

    @ViewBuilder private var tipRows: some View {
        slider("Size", value: $model.tip.size, range: 1...64, shown: "\(model.tip.size) px")
        Toggle("Round", isOn: $model.tip.round).toggleStyle(.checkbox).font(.aeBody)
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
