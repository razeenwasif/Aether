import PhotonDesign
import PhotonGraph
import AppKit
import DiffuseCore
import SwiftUI

/// The inspector shows only what applies to the selection: one node's fields,
/// a few nodes' shared switches, or, with nothing selected, the flow itself.
struct DiffuseInspector: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor

    var body: some View {
        Group {
            if editor.selection.count == 1, let id = editor.selection.first, let node = editor.flow.node(id) {
                NodeInspector(model: model, editor: editor, node: node, type: editor.library.catalogue.node(node.type))
            } else if editor.selection.count > 1 {
                SelectionInspector(model: model, editor: editor)
            } else {
                FlowInspector(model: model, editor: editor)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass()
    }
}

/// The title row every inspector starts with.
struct InspectorHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC9D6FF))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.ice.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ice.opacity(0.22)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.aeTitle).foregroundStyle(Color.inkHi).lineLimit(1)
                Text(subtitle).font(.aeSmall).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - One node

private struct NodeInspector: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor
    let node: FlowNode
    let type: NodeType?

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: GroupStyle.symbol(type?.group ?? ""), title: type?.title ?? node.type,
                            subtitle: "Node \(node.id) · \(type?.group ?? "not on this server")")
            ScrollView {
                VStack(spacing: 0) {
                    if let type, !type.fields.isEmpty {
                        PanelSection("Fields") {
                            VStack(spacing: 8) {
                                ForEach(type.fields, id: \.name) { field in
                                    FieldEditor(model: model, editor: editor, node: node, field: field)
                                }
                            }
                        }
                    }
                    PanelSection("Run") {
                        VStack(spacing: 8) {
                            if type?.fields.contains(where: { $0.fieldKind == .seed }) == true {
                                // On a row of its own: three segments don't fit beside a label.
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Seed after a run").font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                                    Picker("Seed after a run", selection: seedMode) {
                                        ForEach(SeedMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                    .controlSize(.small)
                                }
                            }
                            LabeledRow("Bypass") {
                                Toggle("Leave out of runs", isOn: bypass).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                Spacer()
                            }
                            HStack {
                                Button { model.runTo(node.id) } label: {
                                    Label("Run to here", systemImage: "play.fill").font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(node.isBypassed)
                                .help("Run only what this node needs, and show what it makes on it (⇧⌘↩)")
                                Spacer()
                            }
                        }
                    }
                    let problems = editor.problems(at: node.id)
                    if !problems.isEmpty {
                        PanelSection("Problems") { ProblemList(problems: problems, editor: editor) }
                    }
                    if let output = model.latestOutput(at: node.id) {
                        PanelSection(type?.isOutput == true ? "Latest output" : "Latest run to here") { OutputView(output: output) }
                    }
                }
            }
        }
    }

    private var seedMode: Binding<SeedMode> {
        Binding(get: { node.seed ?? .fixed }, set: { model.apply([.seed(id: node.id, mode: $0)]) })
    }

    private var bypass: Binding<Bool> {
        Binding(get: { node.isBypassed }, set: { model.apply([.bypass(id: node.id, on: $0)]) })
    }
}

/// A label on the left, its control on the right.
struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Color.ink2).frame(width: 72, alignment: .leading)
            content
        }
    }
}

/// A Load Image's picture: what it is, and where to take another from — a
/// file, the Gallery, or one dropped on it.
private struct PictureField: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor
    let node: FlowNode
    let field: String
    @State private var dropping = false

    @State private var maskShare: Double?

    private var name: String? { node.values[field]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    private var maskSaid: String {
        guard let maskShare, maskShare > 0 else { return "No mask: all of it is redrawn" }
        return "\(max(1, Int((maskShare * 100).rounded())))% masked"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name {
                let onDisk = FlowInputs.onDisk(name, flow: editor.url)
                HStack(spacing: 10) {
                    Thumbnail(url: onDisk, side: 200, key: model.sealKey)
                        .id(model.pictureRevision)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(.aeMono).foregroundStyle(Color.inkHi).lineLimit(2).truncationMode(.middle)
                        if onDisk.lastPathComponent.hasSuffix(SealedFiles.suffix) {
                            Label("Sealed", systemImage: "lock.fill").font(.system(size: 10.5)).foregroundStyle(Color.ink2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("No picture yet: choose one, take one from the Gallery or a canvas, or drop one here or on the graph.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let project = model.project, let link = model.link(node: node.id, field: field), let asset = project.asset(link.asset) {
                LinkedPicture(model: model, project: project, link: link, asset: asset)
            }
            HStack(spacing: 6) {
                Button("Choose…") { model.choosePicture(node: node.id, field: field) }
                Button("From the Gallery") { model.pickFromGallery(node: node.id, field: field) }
            }
            .controlSize(.small)
            // A row of its own: beside the others it cut their names short.
            if !model.projectCanvases.isEmpty, !editor.isSealed {
                Menu("From a Canvas") {
                    ForEach(model.projectCanvases, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.useCanvas(at: url, node: node.id, field: field) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
                .help("A canvas, live: each time it's saved, this picture follows")
            }
            if let project = model.project, !editor.isSealed {
                let renders = project.assets.filter { $0.source == .model && $0.newest != nil }
                if !renders.isEmpty {
                    Menu("From a Render") {
                        ForEach(renders) { asset in
                            Button(asset.name) { Task { await model.use(asset, node: node.id, field: field) } }
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .help("A Model render or its depth, live: each new render, this picture follows")
                }
            }
            if name != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Button { Task { await model.openMask(node: node.id, field: field) } } label: {
                        Label("Paint the mask", systemImage: "paintbrush.pointed")
                    }
                    .controlSize(.small)
                    Text(maskSaid).font(.system(size: 11)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
        .overlay(RoundedRectangle(cornerRadius: Radius.field).strokeBorder(dropping ? Color.ice : Color.line2))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: DiffuseWorkspaceModel.isPicture) else { return false }
            Task { await model.usePictureFile(url, node: node.id, field: field) }
            return true
        } isTargeted: { dropping = $0 }
        .task(id: MaskRead(node: node.id, painted: model.maskShares.count, unlocked: model.sealKey != nil)) {
            maskShare = await model.maskShare(node: node.id)
        }
        .task(id: node.id) { await model.refreshProjectCanvases() }
    }
}

/// A Load Image's picture that follows an asset: where it comes from, with a
/// live dot (inspector rule 5), and whether it keeps a version.
private struct LinkedPicture: View {
    @Bindable var model: DiffuseWorkspaceModel
    let project: ProjectGraph
    let link: AssetLink
    let asset: Asset

    var body: some View {
        let shown = project.version(for: link)?.number ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(link.pinned == nil ? Color.live : Color.ink3).frame(width: 7, height: 7)
                Text(asset.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                Text(asset.source.title).font(.aeSmall).foregroundStyle(Color.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(asset.name), from \(asset.source.title), \(link.pinned == nil ? "live" : "kept")")
            Text(link.pinned == nil ? "Live: v\(shown) of \(asset.versions.count). Saving it in \(asset.source.title) updates this picture." : "Keeps v\(shown) of \(asset.versions.count).")
                .font(.system(size: 11)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Picker("Version", selection: Binding(get: { link.pinned ?? 0 }, set: { model.keep($0 == 0 ? nil : $0, for: link) })) {
                    Text("The newest").tag(0)
                    ForEach(asset.versions.reversed(), id: \.number) { version in
                        Text("v\(version.number)" + (version.note.map { " · \($0)" } ?? "")).tag(version.number)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Unlink") { model.unlink(link) }
                    .help("Keep this picture and stop following")
                Button("Show") { model.showSource?(asset) }
                    .help("Open \(asset.name) in \(asset.source.title)")
            }
            .controlSize(.small)
        }
    }
}

/// Where the flow runs — Automatic, this Mac or forge — and this Mac's
/// models, with a download when there are none.
private struct RunsOn: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor

    var body: some View {
        let route = model.route(for: editor)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Runs on", selection: Binding(get: { model.runPlace(for: editor) }, set: { model.setRunPlace($0, for: editor) })) {
                ForEach(RunPlace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            Label(route.why, systemImage: route.local ? "laptopcomputer" : "server.rack")
                .font(.system(size: 11.5)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            if model.localModels.isEmpty {
                downloadRow
            } else {
                ForEach(model.localModels) { local in
                    Text(verbatim: "\(local.name) · \(local.side) × \(local.side)\(local.takesPictures ? "" : " · no image to image")")
                        .font(.aeMono).foregroundStyle(Color.ink2)
                }
                Text("The first run on this Mac prepares the model for its GPU, once; it takes a while.")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var downloadRow: some View {
        let offer = LocalModelOffer.sdxlBase4Bit
        switch model.download.phase {
        case .fetching(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(.ice)
                HStack {
                    Text(verbatim: "\(gigabytes(done)) of \(gigabytes(total))").font(.aeMono).foregroundStyle(Color.ink2)
                    Spacer()
                    Button("Stop", action: model.download.cancel).buttonStyle(.link).font(.system(size: 11.5))
                }
            }
        case .failed(let why):
            Text(why).font(.system(size: 11.5)).foregroundStyle(Color.coral).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.downloadModel(offer) }.controlSize(.small)
        default:
            Text("No image model on this Mac yet.").font(.system(size: 11.5)).foregroundStyle(Color.ink2)
            Button("Download \(offer.name), \(gigabytes(offer.total))") { model.downloadModel(offer) }
                .controlSize(.small)
                .help("Apple's Core ML SDXL from Hugging Face, into Application Support/Photon/Models")
        }
    }

    private func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(2))) + " GB"
    }
}

/// What a Load Image's mask share is read again for.
private struct MaskRead: Hashable {
    let node: String
    let painted: Int
    let unlocked: Bool
}

/// Edits one field. Every change goes to the core as a `set`; a value the
/// core refuses snaps back, and the reason shows under the field.
private struct FieldEditor: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor
    let node: FlowNode
    let field: NodeInput

    @State private var text = ""
    @State private var number: Double = 0
    @State private var refusal: String?
    @FocusState private var focused: Bool

    private var value: JSONValue? { node.values[field.name] ?? field.default }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.multiline == true {
                Text(field.name).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 96)
                    .background(fieldBackground)
                    .focused($focused)
            } else if field.fieldKind == .upload {
                Text(field.name).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                PictureField(model: model, editor: editor, node: node, field: field.name)
            } else {
                LabeledRow(field.name) { control }
            }
            if let refusal {
                Text(refusal).font(.system(size: 10.5)).foregroundStyle(Color.coral).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: value) { if !focused { load() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commitText() } }
    }

    @ViewBuilder private var control: some View {
        switch field.fieldKind {
        case .int, .seed:
            HStack(spacing: 4) {
                numberField
                if field.fieldKind == .seed {
                    Button {
                        commit(.int(Int64.random(in: 0...(Int64(1) << 53 - 1))))
                    } label: {
                        Image(systemName: "dice").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink)
                    .help("A new random seed")
                }
            }
        case .float:
            HStack(spacing: 8) {
                if let min = field.min, let max = field.max, max > min {
                    Slider(value: $number, in: min...max, onEditingChanged: { editing in
                        if !editing { commit(.double(rounded(number))) }
                    })
                    .controlSize(.mini)
                    .tint(Color(hex: 0xC9CDD6))
                }
                numberField.frame(width: 64)
            }
        case .choice:
            choicePicker
        case .text:
            TextField(field.name, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(fieldBackground)
                .focused($focused)
                .onSubmit(commitText)
        case .upload:
            EmptyView()
        case .other:
            Text(value?.display ?? "—").font(.aeMono).foregroundStyle(Color.ink)
        }
    }

    private var numberField: some View {
        TextField(field.name, text: $text)
            .textFieldStyle(.plain)
            .font(.aeMono)
            .foregroundStyle(Color.inkHi)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(fieldBackground)
            .focused($focused)
            .onSubmit(commitText)
    }

    @ViewBuilder private var choicePicker: some View {
        let choices = editor.library.catalogue.choices(from: field.from ?? "", models: editor.library.models)
        if let choices {
            let current = value?.stringValue ?? ""
            Picker(field.name, selection: Binding(get: { current }, set: { commit(.string($0)) })) {
                if !current.isEmpty && !choices.contains(current) {
                    Text("\(current) (not on the server)").tag(current)
                }
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        } else {
            TextField(field.name, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(fieldBackground)
                .focused($focused)
                .onSubmit(commitText)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .fill(Color.raise1)
            .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .strokeBorder(focused ? Color.ice : Color.line2, lineWidth: 1))
    }

    private func load() {
        refusal = nil
        switch value {
        case .string(let s): text = s
        case .some(let v): text = v.display.replacingOccurrences(of: ",", with: "")
        case nil: text = ""
        }
        number = value?.doubleValue ?? field.min ?? 0
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.fieldKind {
        case .int, .seed:
            guard let parsed = Int64(trimmed) else {
                refusal = trimmed.isEmpty ? nil : "\(field.name) is a whole number"
                return load()
            }
            if value?.intValue != parsed { commit(.int(parsed)) }
        case .float:
            guard let parsed = Double(trimmed) else {
                refusal = trimmed.isEmpty ? nil : "\(field.name) is a number"
                return load()
            }
            if value?.doubleValue != parsed { commit(.double(parsed)) }
        case .text, .choice:
            if value?.stringValue != text { commit(.string(text)) }
        default:
            break
        }
    }

    private func commit(_ next: JSONValue) {
        if editor.apply([.set(id: node.id, name: field.name, value: next)]) == nil {
            refusal = editor.refusal
            editor.clearRefusal()
            load()
            refusal = refusal ?? "Refused"
        } else {
            refusal = nil
        }
    }

    private func rounded(_ v: Double) -> Double {
        let step = field.step ?? 0.01
        return (v / step).rounded() * step
    }
}

// MARK: - Several nodes

private struct SelectionInspector: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: "square.on.square", title: "\(editor.selection.count) nodes", subtitle: "Selected together")
            PanelSection("Together") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Bypass or restore  ⌘B", action: model.toggleBypass)
                    Button("Duplicate  ⌘D", action: model.duplicateSelection)
                    Button("Delete  ⌫", role: .destructive, action: model.deleteSelection)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
        }
    }
}

// MARK: - The flow

private struct FlowInspector: View {
    @Bindable var model: DiffuseWorkspaceModel
    let editor: FlowEditor
    @State private var note = ""
    @State private var home = ""
    @State private var away = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(symbol: "point.3.connected.trianglepath.dotted", title: editor.name,
                            subtitle: editor.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            ScrollView {
                VStack(spacing: 0) {
                    PanelSection("Runs on") { RunsOn(model: model, editor: editor) }
                    PanelSection("Server") { server }
                    PanelSection("Catalogue") {
                        Text("\(editor.library.catalogue.nodes.count) node types · \(editor.library.source.label)")
                            .font(.system(size: 11.5)).foregroundStyle(Color.ink)
                    }
                    if !editor.problems.isEmpty {
                        PanelSection("Problems") { ProblemList(problems: editor.problems, editor: editor) }
                    }
                    PanelSection("Runs") { runs }
                    PanelSection("Note") {
                        TextEditor(text: $note)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 70)
                            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
                            .overlay(RoundedRectangle(cornerRadius: Radius.field).strokeBorder(noteFocused ? Color.ice : Color.line2))
                            .focused($noteFocused)
                    }
                }
            }
        }
        .onAppear {
            note = editor.flow.note ?? ""
            home = model.settings.home
            away = model.settings.away
        }
        .onChange(of: editor.flow.note) { if !noteFocused { note = editor.flow.note ?? "" } }
        .onChange(of: noteFocused) { _, focused in
            if !focused, note != (editor.flow.note ?? "") { model.apply([.note(note.isEmpty ? nil : note)]) }
        }
    }

    private var server: some View {
        let health = model.queue.health
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatePill(HealthStyle.label(health), color: HealthStyle.color(health.state))
                Spacer()
                Button("Look again") { Task { await model.lookAgain() } }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
            if health.state != .serving {
                Text(health.message).font(.system(size: 11.5)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            }
            if let gpu = health.status?.gpu {
                Text("\(gpu.name) · \(gb(gpu.used)) of \(gb(gpu.total)) in use").font(.aeMono).foregroundStyle(Color.ink2)
            }
            LabeledRow("At home") { addressField($home) }
            LabeledRow("Away") { addressField($away, prompt: "Tailscale address") }
        }
    }

    private func addressField(_ text: Binding<String>, prompt: String = "") -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.aeMono)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color.raise1))
            .overlay(RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Color.line2))
            .onSubmit { model.update(settings: GatewaySettings(home: home, away: away)) }
    }

    @ViewBuilder private var runs: some View {
        if model.queue.runs.isEmpty {
            Text("No runs yet. Generate with ⌘↩.").font(.system(size: 11.5)).foregroundStyle(Color.ink2)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.queue.runs.prefix(6)) { run in
                    HStack(spacing: 8) {
                        Text(run.flowName).font(.system(size: 12)).foregroundStyle(Color.inkHi)
                        Spacer()
                        Text(RunStyle.label(run.phase)).font(.system(size: 11)).foregroundStyle(RunStyle.color(run.phase)).lineLimit(1)
                    }
                    if let output = run.outputs.last {
                        OutputView(output: output)
                    }
                }
            }
        }
    }

    private func gb(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}

private struct ProblemList: View {
    let problems: [Problem]
    let editor: FlowEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(problems, id: \.self) { problem in
                Button {
                    if let node = problem.node { editor.selection = [node] }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.amber)
                        Text("\(Text(problem.node.map { "Node \($0): " } ?? "").foregroundStyle(Color.ink2))\(Text(problem.message).foregroundStyle(Color.ink))")
                    }
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct OutputView: View {
    let output: RunItem.Output

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(data: output.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
            }
            HStack {
                Text(verbatim: "\(output.width) × \(output.height)").font(.aeMono).foregroundStyle(Color.ink2)
                Spacer()
                if let file = output.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                }
            }
        }
    }
}

// MARK: - Words and colours for states

enum HealthStyle {
    static func label(_ health: Health) -> String {
        switch health.state {
        case .serving: "forge" + (health.status.map { " · \($0.gpu.name)" } ?? "")
        case .looking: "Looking for forge"
        case .offline: "forge isn’t serving"
        case .noKey: "No gateway key"
        case .badKey: "Key refused"
        case .unreachable: "Gateway unreachable"
        case .failing: "Gateway error"
        }
    }

    static func color(_ state: HealthState) -> Color {
        switch state {
        case .serving: .live
        case .looking: .ink2
        case .offline, .noKey, .unreachable: .amber
        case .badKey, .failing: .coral
        }
    }
}

enum RunStyle {
    static func label(_ phase: RunItem.Phase) -> String {
        switch phase {
        case .sending: "Sending"
        case .queued(let position): position == 0 ? "Next up" : "Queued · \(position) ahead"
        case .running: "Running"
        case .done(let seconds): "Done in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }

    static func color(_ phase: RunItem.Phase) -> Color {
        switch phase {
        case .sending, .queued, .running: .ice
        case .done: .live
        case .failed: .coral
        case .cancelled: .ink2
        }
    }
}
