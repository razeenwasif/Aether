import AetherDesign
import AppKit
import CanvasCore
import SwiftUI
import UniformTypeIdentifiers

/// The Canvas workspace: the canvas edge to edge, the canvases floating on
/// its left and the colour, tool and layers on its right, a status bar and
/// a tool dock; with no canvas open, the home page.
public struct CanvasWorkspace: View {
    @Bindable var model: CanvasWorkspaceModel

    public init(model: CanvasWorkspaceModel) {
        self.model = model
    }

    private var leftInset: CGFloat { model.navigatorOpen && model.document != nil ? 264 : 0 }
    private var rightInset: CGFloat { model.inspectorOpen && model.document != nil ? 300 : 0 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let document = model.document {
                CanvasStage(model: model, document: document)
                    .id(ObjectIdentifier(document))
            } else {
                CanvasHome(model: model)
            }

            if let document = model.document {
                HStack(alignment: .top, spacing: 0) {
                    if model.navigatorOpen {
                        CanvasList(model: model)
                            .frame(width: 248)
                            .padding(8)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if model.inspectorOpen {
                        CanvasInspector(model: model, document: document)
                            .frame(width: 284)
                            .padding(8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                CanvasStatusBar(model: model, document: document)
                    .padding(.leading, leftInset + 12)
                    .padding(.top, 12)
            }

            VStack(spacing: 10) {
                if model.leaving != nil, let document = model.document {
                    LeaveBar(model: model, name: document.name).padding(.top, 12)
                }
                Spacer()
                if let notice = model.notice {
                    CanvasNotice(text: notice) { model.notice = nil }
                }
                if let document = model.document {
                    CanvasTimeline(model: model, document: document).padding(.horizontal, 24)
                    CanvasDock(model: model).padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, leftInset)
            .padding(.trailing, rightInset)
        }
        .animation(Motion.panel, value: model.navigatorOpen)
        .animation(Motion.panel, value: model.inspectorOpen)
        .background(Color.obsidian0)
        .sheet(isPresented: Binding(get: { model.askingForNew && model.document != nil }, set: { model.askingForNew = $0 })) {
            NewCanvasForm(model: model, inSheet: true)
                .padding(22)
                .frame(width: 380)
                .background(Color.obsidian1)
        }
        .sheet(isPresented: Binding(get: { model.askingToResize && model.document != nil }, set: { model.askingToResize = $0 })) {
            if let document = model.document {
                ResizeForm(model: model, document: document)
                    .padding(22)
                    .frame(width: 340)
                    .background(Color.obsidian1)
            }
        }
        .sheet(isPresented: Binding(get: { model.askingToExport && model.document != nil }, set: { model.askingToExport = $0 })) {
            if let document = model.document {
                ExportForm(model: model, document: document)
                    .padding(22)
                    .frame(width: 380)
                    .background(Color.obsidian1)
            }
        }
        .modifier(CanvasKeys(model: model))
    }
}

/// Hands the window's keys to the model while the Canvas is on screen.
private struct CanvasKeys: ViewModifier {
    let model: CanvasWorkspaceModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    let used = MainActor.assumeIsolated {
                        event.type == .keyDown ? model.handleKey(event) : model.handleKeyUp(event)
                    }
                    return used ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                model.panning = false
            }
    }
}

// MARK: - The home page

/// No canvas open: the canvases here as cards, and a new one.
private struct CanvasHome: View {
    @Bindable var model: CanvasWorkspaceModel
    @State private var dropping = false

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Canvases").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.inkHi)
                    Spacer()
                    Button("Open…", action: model.chooseAndOpen)
                    Button("Make a Canvas of a Picture…", action: model.chooseAndImport)
                }
                if model.canvases.isEmpty {
                    Text("No canvas here yet. Make one, or drop a PNG, a Photoshop or an Aseprite file here to make a canvas of it.")
                        .font(.aeBody).foregroundStyle(Color.ink2)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 14)], spacing: 14) {
                            ForEach(model.canvases) { file in
                                CanvasCard(file: file) { model.open(file.url) }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    Text("Drop a PNG, a Photoshop or an Aseprite file here to make a canvas of it.")
                        .font(.aeSmall).foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NewCanvasForm(model: model, inSheet: false)
                .padding(18)
                .frame(width: 320)
                .aeGlass(.panel)
        }
        .padding(.horizontal, 40)
        .padding(.top, 48)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.obsidian0)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Color.ice.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                guard let bytes = try? Data(contentsOf: url) else { continue }
                model.receive(bytes, named: url.lastPathComponent, keep: true)
            }
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .onAppear(perform: model.refreshList)
    }
}

/// A canvas as a card: its picture, its name and what it is.
private struct CanvasCard: View {
    let file: CanvasFile
    let open: () -> Void
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Checkerboard()
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(file.preset == .pixel ? .none : .medium)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.field))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                    Text(verbatim: "\(file.preset.title) · \(file.width) × \(file.height)").font(.aeSmall).foregroundStyle(Color.ink2)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Radius.node).fill(hovering ? Color.raise2 : Color.raise1))
            .overlay(RoundedRectangle(cornerRadius: Radius.node).strokeBorder(Color.line2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.url.path)
        .task(id: file) {
            image = await Task.detached { CanvasThumbnail.make(file) }.value
        }
    }
}

/// Grey squares under a picture's clear parts.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.30)))
            for row in 0..<Int(size.height / side) + 1 {
                for col in 0..<Int(size.width / side) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * side, y: CGFloat(row) * side, width: side, height: side)), with: .color(Color(white: 0.22)))
                }
            }
        }
    }
}

/// A new canvas: a name, Pixel or Paint, a size.
/// Writing the canvas out, as Proton's: the frame shown as a PNG, every
/// frame on a sprite sheet with Aseprite's JSON, or the frame shown as a
/// Photoshop file with its layers; the first two as large as asked.
struct ExportForm: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument

    private var format: CanvasExportFormat { model.export.format }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.aeTitle).foregroundStyle(Color.inkHi)
            Picker("As", selection: $model.export.format) {
                ForEach(CanvasExportFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if format != .psd {
                HStack(spacing: 10) {
                    Text("Each pixel").font(.aeSmall).foregroundStyle(Color.ink2)
                    Picker("Each pixel", selection: $model.export.scale) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text(verbatim: "×\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            if format == .sheet {
                Picker("Frames", selection: $model.export.inRow) {
                    Text("As near a square as they make").tag(false)
                    Text("In a row").tag(true)
                }
                .pickerStyle(.radioGroup)
                .font(.aeBody)
            }
            Text(verbatim: note).font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.askingToExport = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { model.exportChosen() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.runFill)
                    .foregroundStyle(Color.obsidian0)
                    .keyboardShortcut(.defaultAction)
                    .disabled(format == .sheet && model.frameCount < 2)
            }
        }
    }

    private var note: String {
        let (w, h) = (document.width * model.export.scale, document.height * model.export.scale)
        switch format {
        case .png:
            return "Frame \(model.frame + 1), flattened: \(w) × \(h)."
        case .sheet:
            guard model.frameCount > 1 else { return "A sheet needs two frames or more." }
            let frames = model.frameCount == 2 ? "Both frames" : "All \(model.frameCount) frames"
            return "\(frames), each \(w) × \(h), on one PNG, and a JSON beside it of where each is, how long it shows and the tags, as Aseprite writes it."
        case .psd:
            let count = document.state.layers.count
            let layers = count == 1 ? "its layer kept, with its opacity and blend" : "its \(count) layers kept, each with its opacity and blend"
            return "Frame \(model.frame + 1), \(layers)."
        }
    }
}

/// The canvas made another size: every layer, by the nearest pixel on a
/// pixel canvas and weighed on a painting.
struct ResizeForm: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument
    // As typed, so a click on Resize takes what is in the fields.
    @State private var width = ""
    @State private var height = ""
    @State private var keepShape = true

    private var most: Int { document.state.preset.most }
    private var size: (Int, Int)? {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)), let h = Int(height.trimmingCharacters(in: .whitespaces)),
              (1...most).contains(w), (1...most).contains(h) else { return nil }
        return (w, h)
    }
    private var fits: Bool { size != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize the canvas").font(.aeTitle).foregroundStyle(Color.inkHi)
            HStack(alignment: .bottom, spacing: 10) {
                // Typing one side sets the other when the shape is kept.
                number("Width", Binding(get: { width }, set: {
                    width = $0
                    if keepShape, let side = Int($0) { height = String(scaled(side, document.width, document.height)) }
                }))
                Text(verbatim: "×").foregroundStyle(Color.ink2).padding(.bottom, 4)
                number("Height", Binding(get: { height }, set: {
                    height = $0
                    if keepShape, let side = Int($0) { width = String(scaled(side, document.height, document.width)) }
                }))
            }
            Toggle("Keep its shape", isOn: $keepShape).toggleStyle(.checkbox).font(.aeBody)
            Text(verbatim: "Now \(document.width) × \(document.height). \(document.state.preset == .pixel ? "By the nearest pixel, so no colours are made" : "Weighed, so it stays smooth"); 1 to \(most) a side.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.askingToResize = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Resize") {
                    guard let (w, h) = size else { return }
                    model.askingToResize = false
                    model.resizeCanvas(width: w, height: h)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.runFill)
                .foregroundStyle(Color.obsidian0)
                .keyboardShortcut(.defaultAction)
                .disabled(!fits)
                .opacity(fits ? 1 : 0.45)
            }
        }
        .onAppear { (width, height) = (String(document.width), String(document.height)) }
    }

    /// `side` of a canvas `from` wide, as `to` would be in proportion.
    private func scaled(_ side: Int, _ from: Int, _ to: Int) -> Int {
        max(1, Int((Double(side) * Double(to) / Double(max(1, from))).rounded()))
    }

    private func number(_ label: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.aeLabel).foregroundStyle(Color.ink2)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
        }
    }
}

struct NewCanvasForm: View {
    @Bindable var model: CanvasWorkspaceModel
    let inSheet: Bool
    @State private var name = ""
    @State private var preset = CanvasPreset.pixel
    @State private var size = 2
    @FocusState private var naming: Bool

    private var sizes: [(Int, Int)] { CanvasWorkspaceModel.sizes[preset] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New canvas").font(.aeTitle).foregroundStyle(Color.inkHi)
            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.aeLabel).foregroundStyle(Color.ink2)
                TextField("Hero sprite", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($naming)
                    .onSubmit(make)
            }
            VStack(alignment: .leading, spacing: 6) {
                presetRow(.pixel, "a small grid, a palette, a pencil")
                presetRow(.paint, "a large canvas and soft brushes")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Size").font(.aeLabel).foregroundStyle(Color.ink2)
                Picker("Size", selection: $size) {
                    ForEach(sizes.indices, id: \.self) { i in
                        Text(verbatim: "\(sizes[i].0) × \(sizes[i].1)").tag(i)
                    }
                }
                .labelsHidden()
            }
            HStack {
                if inSheet {
                    Button("Cancel") { model.askingForNew = false }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Make it", action: make)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.runFill)
                    .foregroundStyle(Color.obsidian0)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .onChange(of: preset) { size = preset == .pixel ? 2 : 1 }
        .onAppear { if inSheet || model.askingForNew { naming = true } }
        .onChange(of: model.askingForNew) { if model.askingForNew { naming = true } }
    }

    private func presetRow(_ value: CanvasPreset, _ blurb: String) -> some View {
        Button {
            preset = value
        } label: {
            HStack(spacing: 10) {
                Image(systemName: preset == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(preset == value ? Color.inkHi : Color.ink3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.title).font(.aeBodyStrong).foregroundStyle(Color.inkHi)
                    Text(blurb).font(.aeSmall).foregroundStyle(Color.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(preset == value ? Color.white.opacity(0.07) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(preset == value ? Color.white.opacity(0.14) : Color.line2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(preset == value ? .isSelected : [])
    }

    private func make() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sizes.indices.contains(size) else { return }
        let (w, h) = sizes[size]
        model.askingForNew = false
        model.newCanvas(named: trimmed, preset: preset, width: w, height: h)
        name = ""
    }
}

// MARK: - Floating over the canvas

/// The canvases, newest first; the open one marked.
private struct CanvasList: View {
    @Bindable var model: CanvasWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Canvases").font(.aeTitle).foregroundStyle(Color.inkHi)
                Spacer()
                Menu {
                    Button("New Canvas…") { model.askingForNew = true }
                    Button("Make a Canvas of a Picture…", action: model.chooseAndImport)
                    Button("Open…", action: model.chooseAndOpen)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("A new canvas")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.canvases) { file in
                        CanvasRow(file: file, isOpen: file.url.standardizedFileURL == model.document?.url.standardizedFileURL) { model.open(file.url) }
                    }
                }
                .padding(6)
            }
            Spacer(minLength: 0)
            Button {
                model.close()
            } label: {
                Label("All canvases", systemImage: "square.grid.2x2").font(.aeBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        }
        .frame(maxHeight: .infinity)
        .aeGlass(.panel)
    }
}

private struct CanvasRow: View {
    let file: CanvasFile
    let isOpen: Bool
    let open: () -> Void
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    Checkerboard()
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(file.preset == .pixel ? .none : .medium).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: Radius.handle))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                    Text(verbatim: "\(file.preset.title) · \(file.width) × \(file.height)").font(.aeSmall).foregroundStyle(Color.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(isOpen ? Color.white.opacity(0.09) : (hovering ? Color.white.opacity(0.04) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .task(id: file) {
            image = await Task.detached { CanvasThumbnail.make(file, side: 96) }.value
        }
    }
}

/// The canvas's name and whether it's saved, what it is, the zoom and the pointer.
private struct CanvasStatusBar: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(document.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi)
                if document.state.dirty {
                    Circle().fill(Color.ink).frame(width: 6, height: 6).help("Not saved: ⌘S")
                }
            }
            Divider().frame(height: 12)
            Text(verbatim: "\(document.state.preset.title) · \(document.width) × \(document.height)").font(.system(size: 11.5)).foregroundStyle(Color.ink)
            Divider().frame(height: 12)
            Text(verbatim: "\(Int((model.viewport.scale * 100).rounded()))%").font(.aeMono).foregroundStyle(Color.ink)
                .help("f fits it, 1 is 100%, pinch or ⌘-scroll to zoom")
            if let p = model.pointer {
                Divider().frame(height: 12)
                Text(verbatim: "\(Int(p.x)), \(Int(p.y))").font(.aeMono).foregroundStyle(Color.ink2)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .aeGlass(.floating, radius: 9)
    }
}

/// The tools, the colour, undo, and the view, centred in the free space.
private struct CanvasDock: View {
    @Bindable var model: CanvasWorkspaceModel

    private var drawingTool: CanvasTool { model.document?.state.preset == .pixel ? .pencil : .brush }
    private var otherTool: CanvasTool { drawingTool == .pencil ? .brush : .pencil }

    var body: some View {
        HStack(spacing: 2) {
            ForEach([drawingTool, otherTool, .eraser, .fill, .pick], id: \.self) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ForEach([CanvasTool.line, .rect, .ellipse], id: \.self) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ForEach([CanvasTool.select, .wand, .move], id: \.self) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ColorWell(model: model).padding(.horizontal, 4)
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("arrow.uturn.backward", label: "Undo \(model.document?.state.undo ?? "") (⌘Z)", action: model.undo)
                .disabled(!(model.document?.state.canUndo ?? false))
            IconButton("arrow.uturn.forward", label: "Redo \(model.document?.state.redo ?? "") (⇧⌘Z)", action: model.redo)
                .disabled(!(model.document?.state.canRedo ?? false))
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("arrow.up.left.and.down.right.magnifyingglass", label: "Fit the canvas in view (f)", action: model.fit)
            IconButton("grid", label: "The pixel grid, from 600% (⇧G)", isOn: model.showGrid) { model.showGrid.toggle() }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .aeGlass(.floating, radius: 12)
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        let key = tool == drawingTool ? "b" : tool == otherTool ? "n" : tool.key
        // The select tool shows the shape it makes; s again steps on.
        let symbol = tool == .select ? model.selectShape.symbol : tool.symbol
        let title = tool == .select ? "Select — \(model.selectShape.title.lowercased()) (s; s again for the next shape)" : "\(tool.title) (\(key))"
        return IconButton(symbol, label: title, isOn: model.tool == tool) { model.tool = tool }
    }
}

/// The colour drawn with, as a swatch that opens the colour panel.
struct ColorWell: View {
    @Bindable var model: CanvasWorkspaceModel
    var side: CGFloat = 24

    var body: some View {
        Button {
            ColorPanelLink.shared.open(for: model)
        } label: {
            ZStack {
                Checkerboard()
                model.color.color
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.5), lineWidth: 1).padding(-1))
        }
        .buttonStyle(.plain)
        .help("The colour drawn with \(model.color.hex): click for the colours, ⌥-click the canvas to pick one")
        .accessibilityLabel("Colour \(model.color.hex)")
    }
}

/// The Mac's colour panel, set to the colour drawn with and setting it.
@MainActor
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    private weak var model: CanvasWorkspaceModel?

    func open(for model: CanvasWorkspaceModel) {
        self.model = model
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = NSColor(model.color.color)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        model?.color = RGBA(Color(nsColor: panel.color))
    }
}

/// Leaving a canvas with changes not saved.
private struct LeaveBar: View {
    @Bindable var model: CanvasWorkspaceModel
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.amber)
            Text("\(name) has changes that are not saved.").font(.system(size: 12)).foregroundStyle(Color.inkHi)
            Button("Stay") { model.answerLeaving(save: nil) }
                .keyboardShortcut(.cancelAction)
            Button("Leave without saving") { model.answerLeaving(save: false) }
            Button("Save and leave") { model.answerLeaving(save: true) }
                .buttonStyle(.borderedProminent)
                .tint(Color.runFill)
                .foregroundStyle(Color.obsidian0)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .aeGlass(.floating, radius: 10)
    }
}

private struct CanvasNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.amber)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.inkHi).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink2)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .aeGlass(.floating, radius: 10)
        .padding(.bottom, 4)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}

extension RGBA {
    /// As SwiftUI's colour, in sRGB.
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    /// A SwiftUI colour, in sRGB, as bytes.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent), byte(ns.alphaComponent))
    }

    /// `#rrggbb`, or `#rrggbbaa` when not opaque.
    var hex: String {
        a == 255 ? String(format: "#%02x%02x%02x", r, g, b) : String(format: "#%02x%02x%02x%02x", r, g, b, a)
    }
}
