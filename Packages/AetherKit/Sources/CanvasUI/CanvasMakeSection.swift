import AetherDesign
import CanvasCore
import SwiftUI

/// The Make panel, as Proton's: a generator (a sprite, noise, caves) and a
/// filter (outline, shadow, pixelate, fewer colours), each shown on the
/// layer chosen as it's set, held to what is selected, and kept as one edit.
struct MakeSection: View {
    @Bindable var model: CanvasWorkspaceModel
    @State private var open = false

    var body: some View {
        PanelSection("Make") {
            Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { open.toggle() } } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink2)
            .help(open ? "Fold the Make panel away" : "Generators and filters")
            .accessibilityLabel(open ? "Hide the Make panel" : "Show the Make panel")
        } content: {
            if open {
                generator
                Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 2)
                filter
                Text(note).font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sprites, noise and caves; outline, shadow, pixelate, fewer colours.")
                    .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.make.generator) { model.showMade(.generator) }
        .onChange(of: model.make.filter) { model.showMade(.filter) }
    }

    private var note: String {
        guard let making = model.making else { return "A change shows it on the layer chosen, held to what is selected." }
        return "Showing the \(making.label.lowercased()) on \(model.currentLayer?.name ?? "the layer"), not kept yet."
    }

    // MARK: The generator

    @ViewBuilder private var generator: some View {
        let g = $model.make.generator
        choose("What", g.what, CanvasMakeSettings.What.allCases) { $0.title }
        switch model.make.generator.what {
        case .sprite:
            choose("Kind", g.template, CanvasSpriteKind.allCases) { $0.title }
            number("Scale", g.scale, 1...16)
            check("In a ramp of the colour drawn with", g.ownColor)
        case .noise:
            choose("Noise", g.noise, CanvasNoiseKind.allCases) { $0.title }
            number("Cell", g.cell, 1...512)
            number("Octaves", g.octaves, 1...8)
            choose("Colours", g.paletteColors, [false, true]) { $0 ? "The palette" : "A ramp of the colour" }
            if !model.make.generator.paletteColors { number("Steps", g.steps, 2...16) }
            choose("Laid out", g.mix, CanvasNoiseMix.allCases) { $0.title }
            if model.make.generator.mix == .dither { choose("Dither", g.dither, [2, 4, 8]) { "\($0) × \($0)" } }
        case .cave:
            number("Rock %", g.density, 1...99)
            number("Rounds", g.rounds, 0...10)
            number("Cell", g.caveCell, 1...64)
            check("Repeats as a tile", g.wrap)
        }
        HStack(spacing: 8) {
            Text("Seed").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
            NumberField(value: Binding(get: { Int(model.make.generator.seed) }, set: { model.make.generator.seed = UInt32(clamping: $0) }), range: 0...Int(UInt32.max))
                .frame(width: 104)
            Button { model.reseed() } label: { Image(systemName: "arrow.clockwise") }
                .controlSize(.small)
                .help("Another seed")
                .accessibilityLabel("Another seed")
        }
        actions(.generator)
    }

    // MARK: The filter

    @ViewBuilder private var filter: some View {
        let f = $model.make.filter
        choose("Filter", f.kind, CanvasMakeSettings.FilterKind.allCases) { $0.title }
        switch model.make.filter.kind {
        case .outline:
            check("Across corners too", f.diagonal)
            check("On its own edge, not round it", f.inside)
        case .shadow:
            number("Across", f.dx, -64...64)
            number("Down", f.dy, -64...64)
            number("Blur", f.blur, 0...64)
            number("Strength %", f.shade, 1...100)
        case .pixelate:
            number("Square", f.size, 2...128)
        case .quantize:
            number("Colours", f.count, 2...64)
            check("The palette's colours instead", f.toPalette)
            choose("Dither", f.ditherColours, [0, 2, 4, 8]) { $0 == 0 ? "Not dithered" : "\($0) × \($0)" }
            check("Keep them as the palette", f.keep)
        }
        actions(.filter)
    }

    // MARK: Rows

    private func actions(_ part: CanvasMakePart) -> some View {
        HStack(spacing: 6) {
            Button("Show it") { model.showMade(part) }
            Button("Keep it") { model.keepMade(part) }
                .buttonStyle(.borderedProminent)
                .tint(Color.runFill)
                .foregroundStyle(Color.obsidian0)
            Button("Leave it") { model.leaveMade() }
                .disabled(model.making?.part != part)
        }
        .controlSize(.small)
    }

    private func choose<T: Hashable>(_ label: String, _ value: Binding<T>, _ options: [T], title: @escaping (T) -> String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
            Picker(label, selection: value) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func number(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
            NumberField(value: value, range: range).frame(width: 64)
            Stepper(label, value: value, in: range).labelsHidden().controlSize(.small)
        }
    }

    private func check(_ label: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value).toggleStyle(.checkbox).font(.aeBody)
    }
}

/// A whole number typed, kept when ↩ is pressed or the field is left, and
/// held to `range`.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.aeMono)
            .controlSize(.small)
            .focused($typing)
            .onSubmit(commit)
            .onChange(of: typing) { if !typing { commit() } }
            .onChange(of: value) { if !typing { text = String(value) } }
            .onAppear { text = String(value) }
    }

    private func commit() {
        guard let typed = Int(text.trimmingCharacters(in: .whitespaces)) else { return text = String(value) }
        let held = min(max(typed, range.lowerBound), range.upperBound)
        if held != value { value = held }
        text = String(held)
    }
}
