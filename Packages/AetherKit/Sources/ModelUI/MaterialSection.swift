import AetherDesign
import AppKit
import ModelCore
import SwiftUI

/// The chosen object's material as a layer stack: the layers over it, top
/// first as a stack is read, and the base at the bottom. A graph the stack
/// can't show is kept as it is, and can be replaced by layers from its base.
struct MaterialSection: View {
    let model: ModelWorkspaceModel
    let document: SceneDocument
    let node: SceneNode

    private var material: SceneMaterial? { model.selectedMaterial }

    var body: some View {
        PanelSection("Material") {
            if let material, model.stack(of: material.id) != nil {
                Menu("Add") {
                    ForEach(LayerPattern.allCases) { pattern in
                        Button { model.addLayer(pattern) } label: { Label("\(pattern.title) Layer", systemImage: pattern.symbol) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .help("A layer over what’s below: everywhere, in noise, or in checks")
            }
        } content: {
            wearing
            if let material {
                if let problem = document.state.shaders.first(where: { $0.id == material.id })?.problem, !problem.isEmpty {
                    Text("Drawn grey: \(problem).").font(.aeSmall).foregroundStyle(Color.amber).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: Binding(get: { model.graphOpen }, set: { _ in model.toggleGraph() })) {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Its node graph, in a drawer under the view: what the file holds")
                if let stack = model.stack(of: material.id) {
                    ForEach(Array(stack.layers.enumerated()).reversed(), id: \.offset) { index, layer in
                        LayerCard(model: model, index: index, count: stack.layers.count, layer: layer)
                    }
                    BaseCard(model: model, base: stack.base)
                } else {
                    let count = material.nodes?.count ?? 0
                    Text("A graph of \(count) node\(count == 1 ? "" : "s"), which the layer stack can’t show. It’s kept as it is.")
                        .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    Button("Replace with Layers", action: model.layersFromGraph)
                        .controlSize(.small)
                        .help("A layer stack whose base is the graph’s surface settings; undo brings the graph back")
                }
            }
        }
    }

    /// What it wears, and a menu to wear another, a new one, or none.
    private var wearing: some View {
        HStack(spacing: 6) {
            if let material {
                NameField(name: material.name, commit: model.renameMaterial)
            } else {
                Text("None: drawn in plain grey.").font(.aeSmall).foregroundStyle(Color.ink2)
            }
            Spacer(minLength: 4)
            Menu(material == nil ? "Choose" : "Change") {
                Button("New Material", action: model.newMaterial)
                let others = document.state.materials.filter { $0.id != node.material }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { one in Button(one.name) { model.wear(one.id) } }
                }
                if material != nil {
                    Divider()
                    Button("None") { model.wear("") }
                }
                if !model.unwornMaterials.isEmpty {
                    Divider()
                    Button("Remove Unworn Materials", action: model.removeUnwornMaterials)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("A new material, one another object wears, or none")
        }
    }
}

/// A material's name, renamed where it's shown: kept on ↩ or when the
/// field is left.
private struct NameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.aeBodyStrong)
            .foregroundStyle(Color.inkHi)
            .focused($typing)
            .onSubmit(done)
            .onChange(of: typing) { if !typing { done() } }
            .onChange(of: name) { if !typing { text = name } }
            .onAppear { text = name }
            .help("Its name: click to rename it")
            .accessibilityLabel("Material name")
    }

    private func done() {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return text = name }
        if typed != name { commit(typed) }
    }
}

/// The base: what shows where no layer covers.
private struct BaseCard: View {
    let model: ModelWorkspaceModel
    let base: SceneSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Base").font(.aeBodyStrong).foregroundStyle(Color.inkHi)
            SurfaceRows(model: model, what: "Base", surface: base) { change in model.editStack(change.label) { change.apply(&$0.base) } }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
    }
}

/// One layer: its pattern, its surface, how much it covers and where.
private struct LayerCard: View {
    let model: ModelWorkspaceModel
    let index: Int
    let count: Int
    let layer: SceneLayer

    private var title: String { "\(layer.pattern.title) Layer" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: layer.pattern.symbol).font(.system(size: 10)).foregroundStyle(Color.ink2)
                Text(layer.pattern.title).font(.aeBodyStrong).foregroundStyle(Color.inkHi)
                Spacer()
                small("arrow.up", "Up the stack") { model.moveLayer(at: index, by: 1) }
                    .disabled(index == count - 1)
                small("arrow.down", "Down the stack") { model.moveLayer(at: index, by: -1) }
                    .disabled(index == 0)
                small("xmark", "Remove it") { model.removeLayer(at: index) }
            }
            SurfaceRows(model: model, what: layer.pattern.title, surface: layer.surface) { change in
                model.editStack(change.label) { if $0.layers.indices.contains(index) { change.apply(&$0.layers[index].surface) } }
            }
            NumberRow("Amount", value: layer.amount, in: 0...1) { v in set("\(layer.pattern.title) Amount") { $0.amount = v } }
            if layer.pattern != .solid {
                HStack(spacing: 6) {
                    Text("Scale").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
                    DecimalField(value: layer.scale) { v in set("\(layer.pattern.title) Scale") { $0.scale = min(1000, max(0.01, v)) } }
                        .frame(width: 64)
                    Text("a metre").font(.aeSmall).foregroundStyle(Color.ink2)
                }
                .help("Cells or blots a metre, in the object’s own space: they stay put as it moves")
            }
            if layer.pattern == .noise {
                NumberRow("Coverage", value: layer.coverage, in: 0...1) { v in set("Noise Coverage") { $0.coverage = v } }
                NumberRow("Edge", value: layer.edge, in: 0...1) { v in set("Noise Edge") { $0.edge = v } }
                HStack(spacing: 6) {
                    Text("Detail").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
                    Stepper(value: Binding(get: { Int(layer.detail) }, set: { v in set("Noise Detail") { $0.detail = Double(v) } }), in: 1...8) {
                        Text("\(Int(layer.detail))").font(.aeMono).foregroundStyle(Color.inkHi)
                    }
                    .controlSize(.small)
                    .help("Octaves: each finer and fainter than the last")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
    }

    private func set(_ label: String, _ change: @escaping (inout SceneLayer) -> Void) {
        model.editStack(label) { if $0.layers.indices.contains(index) { change(&$0.layers[index]) } }
    }

    private func small(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A change to a surface, and the step it's named.
private struct SurfaceChange {
    let label: String
    let apply: (inout SceneSurface) -> Void
}

/// A surface's colour, metal and roughness.
private struct SurfaceRows: View {
    let model: ModelWorkspaceModel
    let what: String
    let surface: SceneSurface
    let change: (SurfaceChange) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Colour").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
            ColorPicker("Colour", selection: Binding(get: { LinearColor.color(surface.color) }, set: { picked in
                let rgb = LinearColor.rgb(picked)
                change(SurfaceChange(label: "\(what) Colour") { $0.color = rgb })
            }), supportsOpacity: false)
            .labelsHidden()
            Text(LinearColor.hex(surface.color)).font(.aeMono).foregroundStyle(Color.ink2)
        }
        NumberRow("Metal", value: surface.metallic, in: 0...1) { v in change(SurfaceChange(label: "\(what) Metal") { $0.metallic = v }) }
        NumberRow("Roughness", value: surface.roughness, in: 0...1) { v in change(SurfaceChange(label: "\(what) Roughness") { $0.roughness = v }) }
    }
}

/// A number from 0 to 1 by a slider, with its value beside it.
private struct NumberRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    init(_ title: String, value: Double, in range: ClosedRange<Double>, set: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.set = set
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 * 100).rounded() / 100) }), in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(String(format: "%.2f", value)).font(.aeMono).foregroundStyle(Color.ink2).frame(width: 34, alignment: .trailing)
        }
    }
}

/// A material's colours are linear RGB, as shaders want them; the colour
/// well shows and picks them as colours.
enum LinearColor {
    private static let space = CGColorSpace(name: CGColorSpace.linearSRGB)!

    static func color(_ rgb: [Double]) -> Color {
        let c = (0..<3).map { CGFloat(rgb.count > $0 ? rgb[$0] : 0) }
        return CGColor(colorSpace: space, components: [c[0], c[1], c[2], 1]).map { Color(cgColor: $0) } ?? .gray
    }

    static func rgb(_ color: Color) -> [Double] {
        guard let ns = NSColor(color).usingColorSpace(NSColorSpace(cgColorSpace: space)!) else { return [0.8, 0.8, 0.8] }
        return [ns.redComponent, ns.greenComponent, ns.blueComponent].map { (Double($0) * 1e4).rounded() / 1e4 }.map { min(1, max(0, $0)) }
    }

    /// As sRGB hex, the way a colour is usually written down.
    static func hex(_ rgb: [Double]) -> String {
        guard let ns = NSColor(color(rgb)).usingColorSpace(.sRGB) else { return "" }
        let v = [ns.redComponent, ns.greenComponent, ns.blueComponent].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }
}
