import AetherDesign
import AppKit
import ModelCore
import SwiftUI

/// The Model workspace: the Metal viewport edge to edge, the outliner
/// floating on its left and the object's inspector on its right, a status
/// bar and a dock; with no scene open, the scenes.
public struct ModelWorkspace: View {
    @Bindable var model: ModelWorkspaceModel

    public init(model: ModelWorkspaceModel) {
        self.model = model
    }

    private var leftInset: CGFloat { model.navigatorOpen && model.document != nil ? 264 : 0 }
    private var rightInset: CGFloat { model.inspectorOpen && model.document != nil ? 300 : 0 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let document = model.document {
                ModelViewport(model: model, camera: model.camera, selected: model.selected, revision: document.revision, editRevision: model.editing?.revision ?? -1)
                    .id(ObjectIdentifier(document))
                HStack(alignment: .top, spacing: 0) {
                    if model.navigatorOpen {
                        Outliner(model: model, document: document)
                            .frame(width: 248)
                            .padding(8)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if model.inspectorOpen {
                        ModelInspector(model: model, document: document)
                            .frame(width: 284)
                            .padding(8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                ModelStatusBar(model: model, document: document)
                    .padding(.leading, leftInset + 12)
                    .padding(.top, 12)
            } else {
                ModelHome(model: model)
            }

            VStack(spacing: 10) {
                Spacer()
                if model.graphOpen, model.editing == nil, let material = model.selectedMaterial {
                    MaterialGraphDrawer(model: model, material: material, isStack: model.stack(of: material.id) != nil)
                        .frame(height: 250)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let notice = model.notice {
                    ModelNotice(text: notice) { model.notice = nil }
                }
                if model.document != nil {
                    ModelDock(model: model).padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, leftInset)
            .padding(.trailing, rightInset)
        }
        .animation(Motion.panel, value: model.navigatorOpen)
        .animation(Motion.panel, value: model.inspectorOpen)
        .animation(Motion.panel, value: model.graphOpen)
        .background(Color.obsidian0)
        .modifier(ModelKeys(model: model))
    }
}

/// Hands the window's keys to the model while Model is on screen.
private struct ModelKeys: ViewModifier {
    let model: ModelWorkspaceModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { model.handleKey(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

// MARK: - The scenes

/// No scene open: the scenes in the project as cards, and a new one.
private struct ModelHome: View {
    @Bindable var model: ModelWorkspaceModel
    @State private var name = ""
    @FocusState private var naming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Scenes").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.inkHi)
                    Spacer()
                    Button("Open…", action: model.chooseAndOpen)
                }
                if model.scenes.isEmpty {
                    Text("No scene here yet. A scene places meshes — .obj files beside it, from Blender or made here — lights and cameras, and keeps each one's modifiers.")
                        .font(.aeBody).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(model.scenes) { scene in
                                Button { model.open(scene.url) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Image(systemName: "cube.transparent").font(.system(size: 34, weight: .light)).foregroundStyle(Color.ink2)
                                            .frame(maxWidth: .infinity, minHeight: 96)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.raise1))
                                        Text(scene.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                                        Text(scene.modified, style: .date).font(.aeSmall).foregroundStyle(Color.ink2)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(scene.name)")
                            }
                        }
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("New scene").font(.aeTitle).foregroundStyle(Color.inkHi)
                TextField("Name", text: $name, prompt: Text("Room"))
                    .textFieldStyle(.roundedBorder)
                    .focused($naming)
                    .onSubmit(make)
                Text("It starts with a cube, so there's something to turn round.").font(.aeSmall).foregroundStyle(Color.ink2)
                HStack {
                    Spacer()
                    Button("Make it", action: make)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.runFill)
                        .foregroundStyle(Color.obsidian0)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 280)
            .aeGlass(.panel)
        }
        .padding(28)
        .padding(.leading, 8)
        .onAppear(perform: model.refreshList)
        .onChange(of: model.askingForNew, initial: true) {
            guard model.askingForNew else { return }
            naming = true
            model.askingForNew = false
        }
    }

    private func make() {
        model.newScene(named: name)
        name = ""
    }
}

// MARK: - The outliner

/// Every object, parents above children, indented by depth: click to choose,
/// double-click to rename.
private struct Outliner: View {
    @Bindable var model: ModelWorkspaceModel
    let document: SceneDocument
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Outliner").font(.aeLabel).foregroundStyle(Color.ink2)
                Spacer()
                AddMenu(model: model)
                Button { model.removeSelected() } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .disabled(model.selected == nil)
                .help("Remove it, and what's under it (⌫)")
                .accessibilityLabel("Remove the object chosen")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if document.state.objects.isEmpty {
                Text("Nothing in the scene yet: ＋ adds a mesh, a light, a camera or an empty.")
                    .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(document.state.objects) { node in
                        row(node)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }

    private func symbol(_ node: SceneNode) -> String {
        switch node.kind {
        case "mesh": node.modifiers.isEmpty ? "cube" : "cube.fill"
        case "light": "lightbulb"
        case "camera": "camera"
        case "empty": "move.3d"
        default: "questionmark.square.dashed"
        }
    }

    private func row(_ node: SceneNode) -> some View {
        let chosen = node.id == model.selected
        // A button, so a click, VoiceOver and Press all choose it.
        return Button { model.choose(node.id) } label: { rowLabel(node, chosen: chosen) }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { rename(node) })
            .contextMenu {
                Button("Rename") { rename(node) }
                Button("Frame It") {
                    model.choose(node.id)
                    model.frameSelected()
                }
                if !node.parent.isEmpty {
                    Button("Move to the Top") { model.change(.reparent(node.id, parent: ""), label: "Unparent") }
                }
                Divider()
                Button("Remove") {
                    model.choose(node.id)
                    model.removeSelected()
                }
            }
            .accessibilityLabel("\(node.name), \(node.kindTitle)")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityAction(named: "Rename") { rename(node) }
    }

    private func rename(_ node: SceneNode) {
        newName = node.name
        renaming = node.id
    }

    private func rowLabel(_ node: SceneNode, chosen: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(node)).font(.system(size: 11)).foregroundStyle(chosen ? Color.ice : Color.ink2).frame(width: 18)
            if renaming == node.id {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.aeBody)
                    .onSubmit {
                        renaming = nil
                        if newName.trimmingCharacters(in: .whitespaces) != node.name {
                            model.change(.rename(node.id, name: newName), label: "Rename")
                        }
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(node.name).font(chosen ? .aeBodyStrong : .aeBody).foregroundStyle(Color.inkHi).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !node.modifiers.isEmpty {
                Text("\(node.modifiers.count)").font(.aeMono).foregroundStyle(Color.ink3)
                    .help("\(node.modifiers.count) modifier\(node.modifiers.count == 1 ? "" : "s")")
            }
        }
        .padding(.leading, 6 + CGFloat(node.depth) * 14)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.button).fill(chosen ? Color.white.opacity(0.09) : .clear))
        .contentShape(Rectangle())
    }
}

/// ＋: what can be added to the scene.
private struct AddMenu: View {
    let model: ModelWorkspaceModel

    var body: some View {
        Menu {
            ForEach(SceneAddition.allCases.filter(\.isMesh)) { addition in
                Button { model.add(addition) } label: { Label(addition.title, systemImage: addition.symbol) }
            }
            Divider()
            ForEach(SceneAddition.allCases.filter { !$0.isMesh }) { addition in
                Button { model.add(addition) } label: { Label(addition.title, systemImage: addition.symbol) }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a mesh, a light, a camera or an empty")
        .accessibilityLabel("Add")
    }
}

// MARK: - The inspector

/// Only what applies to the object chosen: its transform, its mesh, its
/// modifiers (inspector rules 1–3).
private struct ModelInspector: View {
    @Bindable var model: ModelWorkspaceModel
    let document: SceneDocument

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let node = model.selectedNode, let edit = model.editing, edit.nodeID == node.id {
                    header(node, editing: true)
                    EditSection(model: model, edit: edit)
                } else if let node = model.selectedNode {
                    header(node)
                    TransformSection(model: model, node: node)
                    if node.kind == "mesh" {
                        MeshSection(model: model, document: document, node: node)
                        ModifiersSection(model: model, node: node)
                    }
                    if node.kind == "mesh" || !node.material.isEmpty {
                        MaterialSection(model: model, document: document, node: node)
                    }
                } else {
                    PanelSection("Scene") {
                        Text("\(document.state.objects.count) object\(document.state.objects.count == 1 ? "" : "s"). Click one in the viewport or the outliner to choose it.")
                            .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }

    private func header(_ node: SceneNode, editing: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(node.name).font(.aeTitle).foregroundStyle(Color.inkHi).lineLimit(1)
            Text(editing ? "· Editing its mesh" : "· \(node.kindTitle)").font(.aeBody).foregroundStyle(editing ? Color.ice : Color.ink2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// Where it is, how it's turned, how large: metres, degrees, a multiplier.
private struct TransformSection: View {
    let model: ModelWorkspaceModel
    let node: SceneNode

    var body: some View {
        PanelSection("Transform") {
            ForEach(ScenePart.allCases, id: \.self) { part in
                let value = part == .position ? node.position : part == .rotation ? node.rotation : node.scale
                HStack(spacing: 6) {
                    Text(part.title).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 52, alignment: .leading)
                    ForEach(0..<3, id: \.self) { axis in
                        DecimalField(value: value.count > axis ? value[axis] : 0, axis: axis) { typed in
                            var next = value
                            while next.count < 3 { next.append(part == .scale ? 1 : 0) }
                            next[axis] = typed
                            model.setTransform(node.id, part, next)
                        }
                    }
                }
            }
        }
    }
}

/// A number typed, kept on ↩ or when the field is left.
struct DecimalField: View {
    let value: Double
    var axis: Int?
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var typing: Bool

    private static let tints: [Color] = [Color(red: 0.86, green: 0.38, blue: 0.38), Color(red: 0.45, green: 0.78, blue: 0.5), Color(red: 0.38, green: 0.52, blue: 0.92)]

    var body: some View {
        TextField(axis.map { ["x", "y", "z"][$0] } ?? "amount", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.aeMono)
            .controlSize(.small)
            .focused($typing)
            .overlay(alignment: .bottom) {
                if let axis { Rectangle().fill(Self.tints[axis].opacity(0.7)).frame(height: 1).padding(.horizontal, 4) }
            }
            .onSubmit(done)
            .onChange(of: typing) { if !typing { done() } }
            .onChange(of: value) { if !typing { text = Self.format(value) } }
            .onAppear { text = Self.format(value) }
            .accessibilityLabel(axis.map { ["x", "y", "z"][$0] } ?? "amount")
    }

    private func done() {
        guard let typed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), typed.isFinite else { return text = Self.format(value) }
        if abs(typed - value) > 1e-9 { commit(typed) }
        text = Self.format(typed)
    }

    static func format(_ v: Double) -> String {
        let s = String(format: "%.3f", v)
        var t = s
        while t.contains("."), t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }
}

/// Edit mode: what's chosen, and what to do to it.
private struct EditSection: View {
    @Bindable var model: ModelWorkspaceModel
    let edit: MeshEditSession

    private var summary: String {
        let (one, many, total) = switch edit.part {
        case .vertices: ("corner", "corners", edit.cage.vertexCount)
        case .edges: ("edge", "edges", edit.cage.edges.count)
        case .faces: ("face", "faces", edit.cage.faceCount)
        }
        let n = edit.chosenCount
        return n == 0 ? "None of its \(total) \(total == 1 ? one : many) chosen." : "\(n) of \(total) \(total == 1 ? one : many) chosen."
    }

    var body: some View {
        PanelSection("Edit mode") {
            Picker("Choose", selection: Binding(get: { edit.part }, set: { model.showPart($0) })) {
                ForEach(EditPart.allCases) { part in Text(part.title).tag(part) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Corners, edges or faces: 1, 2, 3")
            Text(summary).font(.aeSmall).foregroundStyle(Color.ink2)
            row("Extrude", key: "e", value: model.extrudeDistance, unit: "m out", set: { model.extrudeDistance = $0 }, action: model.extrudeChosen)
            row("Inset", key: "i", value: model.insetAmount, unit: "m in", set: { model.insetAmount = $0 }, action: model.insetChosen)
            row("Bevel", key: "b", value: model.bevelWidth, unit: "m wide", set: { model.bevelWidth = $0 }, action: model.bevelChosen)
            row("Loop Cut", key: "⌘R", value: model.cutAt, unit: "along", set: { model.cutAt = min(0.98, max(0.02, $0)) }, action: model.loopCutChosen)
            HStack {
                Button("Delete", role: .destructive, action: model.deleteChosen)
                    .controlSize(.small)
                    .disabled(edit.isEmpty)
                Spacer()
                Button("Done  ⇥") { model.exitEdit() }
                    .controlSize(.small)
            }
            Text("Drag what’s chosen to slide it along its normal; ⌥-drag pulls the faces out first. ⇧-click adds or takes away. Its modifiers are back when you’re done.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: String, key: String, value: Double, unit: String, set: @escaping (Double) -> Void, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(title, action: action)
                .controlSize(.small)
                .frame(width: 84, alignment: .leading)
                .help("\(title) (\(key))")
            DecimalField(value: value, commit: set).frame(width: 64)
            Text(unit).font(.aeSmall).foregroundStyle(Color.ink2)
            Spacer()
        }
    }
}

/// The `.obj` it draws, and how many triangles that comes to.
private struct MeshSection: View {
    let model: ModelWorkspaceModel
    let document: SceneDocument
    let node: SceneNode

    var body: some View {
        PanelSection("Mesh") {
            let mesh = document.mesh(for: node)
            HStack(spacing: 8) {
                Text(node.mesh.isEmpty ? "None" : node.mesh).font(.aeMono).foregroundStyle(Color.inkHi).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseMesh(for: node.id) }.controlSize(.small)
            }
            Button("Edit the Mesh  ⇥") { model.enterEdit() }
                .controlSize(.small)
                .disabled(node.mesh.isEmpty || mesh.problem != nil)
                .help("Choose its corners, edges or faces, and extrude, inset or cut them")
            if let problem = mesh.problem {
                Text("Drawn as a box: \(problem).").font(.aeSmall).foregroundStyle(Color.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(mesh.triangleCount.formatted()) triangles\(node.modifiers.isEmpty ? "" : " after its modifiers")\(mesh.closed ? ", a solid" : ", open").")
                    .font(.aeSmall).foregroundStyle(Color.ink2)
            }
        }
    }
}

/// What's done to its geometry before it's drawn, in order, and never to
/// the file: mirror, array, subdivide.
private struct ModifiersSection: View {
    let model: ModelWorkspaceModel
    let node: SceneNode

    var body: some View {
        PanelSection("Modifiers") {
            Menu("Add") {
                ForEach(SceneModifier.kinds, id: \.self) { kind in
                    Button(kind.capitalized) { model.addModifier(kind, to: node.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Mirror, array or subdivide: kept beside the mesh, never written into it")
        } content: {
            if node.modifiers.isEmpty {
                Text("None. They run in order, and the .obj is never changed.").font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(node.modifiers.enumerated()), id: \.offset) { index, modifier in
                card(index, modifier)
            }
        }
    }

    private func card(_ index: Int, _ m: SceneModifier) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle(m.title, isOn: Binding(get: { !m.off }, set: { model.setModifier(node.id, index, "off", $0 ? "false" : "true") }))
                    .toggleStyle(.checkbox).font(.aeBodyStrong)
                    .disabled(!m.known)
                Spacer()
                small("arrow.up", "Earlier") { model.change(.moveModifier(node.id, index: index, to: index - 1), label: "Move Modifier") }
                    .disabled(index == 0)
                small("arrow.down", "Later") { model.change(.moveModifier(node.id, index: index, to: index + 1), label: "Move Modifier") }
                    .disabled(index == node.modifiers.count - 1)
                small("xmark", "Remove it") { model.change(.removeModifier(node.id, index: index), label: "Remove \(m.title)") }
            }
            if !m.known {
                Text("Not understood by this version: kept, not applied.").font(.aeSmall).foregroundStyle(Color.amber)
            } else {
                switch m.kind {
                case "mirror":
                    HStack(spacing: 8) {
                        Picker("Across", selection: Binding(get: { m.axis }, set: { model.setModifier(node.id, index, "axis", $0) })) {
                            ForEach(["x", "y", "z"], id: \.self) { Text($0.uppercased()).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        Toggle("Weld", isOn: Binding(get: { m.weld }, set: { model.setModifier(node.id, index, "weld", $0 ? "true" : "false") }))
                            .toggleStyle(.checkbox).font(.aeBody)
                            .help("Merge the vertices on the mirror, so a subdivision after it doesn't split the seam")
                    }
                case "array":
                    HStack(spacing: 6) {
                        Text("Copies").font(.aeSmall).foregroundStyle(Color.ink2)
                        Stepper(value: Binding(get: { m.count }, set: { model.setModifier(node.id, index, "count", String($0)) }), in: 1...64) {
                            Text("\(m.count)").font(.aeMono).foregroundStyle(Color.inkHi)
                        }
                        .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Text("Apart").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 40, alignment: .leading)
                        ForEach(0..<3, id: \.self) { axis in
                            DecimalField(value: m.offset.count > axis ? m.offset[axis] : 0, axis: axis) { typed in
                                var next = m.offset
                                while next.count < 3 { next.append(0) }
                                next[axis] = typed
                                model.setModifier(node.id, index, "offset", next.map { String($0) }.joined(separator: ","))
                            }
                        }
                    }
                case "subdivide":
                    HStack(spacing: 6) {
                        Text("Levels").font(.aeSmall).foregroundStyle(Color.ink2)
                        Stepper(value: Binding(get: { m.levels }, set: { model.setModifier(node.id, index, "levels", String($0)) }), in: 0...6) {
                            Text("\(m.levels)").font(.aeMono).foregroundStyle(Color.inkHi)
                        }
                        .controlSize(.small)
                        .help("Each level is four times the triangles of the last")
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
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

// MARK: - Bars

private struct ModelStatusBar: View {
    let model: ModelWorkspaceModel
    let document: SceneDocument

    var body: some View {
        HStack(spacing: 10) {
            Text(document.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi)
            if model.editing != nil {
                Text("Edit mode").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.obsidian0)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.ice))
            }
            Divider().frame(height: 12)
            Text(verbatim: "\(model.stats.objects) object\(model.stats.objects == 1 ? "" : "s") · \(model.stats.triangles.formatted()) triangle\(model.stats.triangles == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Color.ink)
            Divider().frame(height: 12)
            Text(verbatim: String(format: "%.2f ms", model.stats.gpuMilliseconds)).font(.aeMono).foregroundStyle(Color.ink2)
                .help("What the GPU took for the last frame: the budget is 5 ms at 120 Hz")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .aeGlass(.floating, radius: 9)
    }
}

private struct ModelDock: View {
    let model: ModelWorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            if let edit = model.editing {
                editing(edit)
            } else {
                adding
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("arrow.uturn.backward", label: "Undo \(model.undoLabel ?? "") (⌘Z)", action: model.undo)
                .disabled(model.undoLabel == nil)
            IconButton("arrow.uturn.forward", label: "Redo \(model.redoLabel ?? "") (⇧⌘Z)", action: model.redo)
                .disabled(model.redoLabel == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .aeGlass(.floating, radius: 12)
    }

    @ViewBuilder private func editing(_ edit: MeshEditSession) -> some View {
        ForEach(EditPart.allCases) { part in
            IconButton(part == .vertices ? "circle.grid.2x2" : part == .edges ? "line.diagonal" : "square.fill", label: "\(part.title) (\(part.key))", isOn: edit.part == part) { model.showPart(part) }
        }
        Divider().frame(height: 20).padding(.horizontal, 4)
        IconButton("arrow.up.square", label: "Extrude (e)", action: model.extrudeChosen)
        IconButton("square.inset.filled", label: "Inset (i)", action: model.insetChosen)
        IconButton("skew", label: "Bevel (b)", action: model.bevelChosen)
        IconButton("rectangle.split.2x1", label: "Loop Cut (⌘R)", action: model.loopCutChosen)
        IconButton("trash", label: "Delete (⌫)", action: model.deleteChosen)
        Divider().frame(height: 20).padding(.horizontal, 4)
        IconButton("viewfinder", label: "Frame what’s chosen (f)", action: model.frameSelected)
        IconButton("checkmark", label: "Done (⇥)", action: model.exitEdit)
    }

    @ViewBuilder private var adding: some View {
            ForEach([SceneAddition.cube, .sphere, .cylinder, .plane], id: \.self) { addition in
                IconButton(addition.symbol, label: "Add a \(addition.rawValue)") { model.add(addition) }
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ForEach([SceneAddition.light, .camera, .empty], id: \.self) { addition in
                IconButton(addition.symbol, label: "Add \(addition == .empty ? "an empty" : "a \(addition.rawValue)")") { model.add(addition) }
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("viewfinder", label: "Frame it (f)", action: model.frameSelected)
            IconButton("pencil.and.outline", label: "Edit the mesh (⇥)", action: model.enterEdit)
                .disabled(!model.canEdit)
    }
}

private struct ModelNotice: View {
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
