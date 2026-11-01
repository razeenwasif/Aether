import AetherDesign
import AetherGraph
import AppKit
import DesignCore
import SwiftUI

/// The Design workspace: with a design open, its page drawn at each
/// breakpoint edge to edge, its layers and tokens floating on the left, the
/// chosen layer on the right and its code in a drawer (⌘/); with none, the
/// designs.
public struct DesignWorkspace: View {
    @Bindable var model: DesignWorkspaceModel

    public init(model: DesignWorkspaceModel) {
        self.model = model
    }

    private var leftInset: CGFloat { model.navigatorOpen && model.document != nil ? 264 : 0 }
    private var rightInset: CGFloat { model.inspectorOpen && model.document != nil ? 300 : 0 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let document = model.document {
                DesignCanvas(model: model, revision: document.revision &+ model.pictureRevision, pageID: model.componentID.map { "component:\($0)" } ?? model.pageID, selection: model.selection, editing: model.overriding?.key, fitRequest: model.fitRequest,
                             insets: (model.navigatorOpen ? 264 : 0, model.inspectorOpen ? 300 : 0, model.codeOpen ? 260 : 72))
                HStack(alignment: .top, spacing: 0) {
                    DesignNavigator(model: model, document: document)
                        .frame(width: 248)
                        .padding(8)
                        .sliding(open: model.navigatorOpen, from: .leading, by: 264)
                    Spacer(minLength: 0)
                    DesignInspector(model: model, document: document)
                        .frame(width: 284)
                        .padding(8)
                        .sliding(open: model.inspectorOpen, from: .trailing, by: 300)
                }
                DesignStatusBar(model: model, document: document)
                    .padding(.leading, 12)
                    .offset(x: leftInset)
                    .padding(.top, 12)
            } else {
                DesignHome(model: model)
            }
            VStack(spacing: 10) {
                Spacer()
                if let notice = model.notice {
                    DesignNotice(text: notice, good: model.noticeIsGood) { model.notice = nil }
                }
                if model.document != nil {
                    if model.codeOpen { CodeDrawer(model: model).padding(.horizontal, 12) }
                    DesignDock(model: model).padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, leftInset)
            .padding(.trailing, rightInset)
        }
        .animation(Motion.panel, value: model.navigatorOpen)
        .animation(Motion.panel, value: model.inspectorOpen)
        .animation(Motion.panel, value: model.codeOpen)
        .background(Color.obsidian0)
    }
}

// MARK: - Home

private struct DesignHome: View {
    @Bindable var model: DesignWorkspaceModel

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Designs").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.inkHi)
                if model.designs.isEmpty {
                    Text("No design here yet. A design is a folder a diff can read: design.json, a theme.css of tokens in Proton's format, and a file a page — its layers laid out as flexbox lays them out, and written out as HTML and CSS.")
                        .font(.aeBody).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(model.designs) { design in
                                Button { model.open(design.url) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Image(systemName: "rectangle.3.group").font(.system(size: 34, weight: .light)).foregroundStyle(Color.ink2)
                                            .frame(maxWidth: .infinity, minHeight: 96)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.raise1))
                                        Text(design.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                                        Text(verbatim: "\(design.pages) page\(design.pages == 1 ? "" : "s")").font(.aeSmall).foregroundStyle(Color.ink2)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(design.name)")
                            }
                        }
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("New design").font(.aeTitle).foregroundStyle(Color.inkHi)
                TextField("Name", text: $model.newName, prompt: Text("Lumen"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.create)
                Text("A landing page at Desktop and Mobile widths — a nav, a hero and three feature cards — every colour, space and font in it a token of its theme.css.")
                    .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Make it", action: model.create)
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
    }
}

// MARK: - Navigator

/// The page's layers as a tree, or the theme's tokens.
private struct DesignNavigator: View {
    @Bindable var model: DesignWorkspaceModel
    let document: DesignDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Show", selection: $model.navigatorTab) {
                ForEach(DesignNavigatorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            switch model.navigatorTab {
            case .layers: layers
            case .tokens: TokensList(model: model, document: document)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }

    @ViewBuilder private var layers: some View {
        if document.view.pages.count > 1 {
            ForEach(document.view.pages) { row in
                Button { model.pageID = row.id } label: {
                    HStack {
                        Text(row.name).font(.aeBody).foregroundStyle(row.id == model.pageID ? Color.inkHi : Color.ink)
                        if row.dirty { Circle().fill(Color.amber).frame(width: 5, height: 5).accessibilityLabel("unsaved") }
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
        }
        if let page = model.page {
            HStack {
                if let component = model.component {
                    Button { model.closeComponent() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.ink2)
                    .help("Back to the page").accessibilityLabel("Back to the page")
                    Text(component.name).font(.aeLabel).foregroundStyle(Color.ink2)
                    Text(verbatim: "component · \(component.options.count) option\(component.options.count == 1 ? "" : "s")").font(.aeSmall).foregroundStyle(Color.ink3)
                } else {
                    Text(page.name).font(.aeLabel).foregroundStyle(Color.ink2)
                    Text(verbatim: "\(page.breakpoints.count) breakpoint\(page.breakpoints.count == 1 ? "" : "s")").font(.aeSmall).foregroundStyle(Color.ink3)
                }
                Spacer()
                Menu {
                    Button("Frame  A") { model.add(.frame) }
                    Button("Text  T") { model.add(.text) }
                    Button("Shape  R") { model.add(.rect) }
                    Divider()
                    Button("Image from a File…") { model.chooseImageFile() }
                    if document.view.components.contains(where: { $0.id != model.componentID }) {
                        Menu("Component") {
                            ForEach(document.view.components.filter { $0.id != model.componentID }) { row in
                                Button(row.name) { model.place(component: row.id) }
                            }
                        }
                    }
                    if model.component == nil, !model.assets.isEmpty {
                        Menu("Image That Follows") {
                            ForEach(model.assets) { asset in
                                Button("\(asset.name) · \(asset.source.title)") { model.addImage(from: asset) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a layer inside the chosen frame, or after the chosen layer")
                .accessibilityLabel("Add a layer")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        let here = model.pageHere ?? page
                        ForEach(page.tree(), id: \.layer.id) { row in
                            LayerRow(model: model, layer: row.layer, depth: row.depth, isRoot: row.layer.id == page.root, hidden: here.layer(row.layer.id)?.hidden == true)
                                .id(row.layer.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { withAnimation { scroller.scrollTo(id) } }
                }
            }
            if model.component == nil, !document.view.components.isEmpty {
                ComponentsList(model: model, rows: document.view.components)
            }
        }
    }
}

/// The design's components: each one's uses, and a click to edit it.
private struct ComponentsList: View {
    let model: DesignWorkspaceModel
    let rows: [DesignView.ComponentRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 4)
            Text("Components").font(.aeLabel).foregroundStyle(Color.ink2)
                .padding(.horizontal, 14).padding(.bottom, 4)
            ForEach(rows) { row in
                Button { model.editComponent(row.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond").font(.system(size: 10)).foregroundStyle(Color.lavender).frame(width: 12)
                        Text(row.name).font(.aeBody).foregroundStyle(Color.ink).lineLimit(1)
                        if row.dirty { Circle().fill(Color.amber).frame(width: 5, height: 5).accessibilityLabel("unsaved") }
                        Spacer(minLength: 4)
                        Text(verbatim: "\(row.uses.count) use\(row.uses.count == 1 ? "" : "s")").font(.aeSmall).foregroundStyle(Color.ink3)
                    }
                    .padding(.horizontal, 14).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit \(row.name): what changes here changes every page that places it")
                .accessibilityLabel("Edit the component \(row.name), \(row.uses.count) uses")
                .contextMenu {
                    Button("Place on the Page") { model.place(component: row.id) }
                }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct LayerRow: View {
    let model: DesignWorkspaceModel
    let layer: DesignLayer
    let depth: Int
    let isRoot: Bool
    /// Hidden at the breakpoint being edited.
    let hidden: Bool

    private var chosen: Bool { model.selection == layer.id }

    var body: some View {
        Button { model.selection = layer.id } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Color.ink3).frame(width: 12)
                Text(layer.label).font(.aeBody).foregroundStyle(chosen ? Color.inkHi : Color.ink).lineLimit(1)
                    .opacity(hidden ? 0.45 : 1)
                if hidden {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(Color.ink3).accessibilityLabel("hidden here")
                }
                Spacer(minLength: 4)
                if layer.kind == .text {
                    Text(layer.text).font(.aeSmall).foregroundStyle(Color.ink3).lineLimit(1).frame(maxWidth: 80, alignment: .trailing)
                }
            }
            .padding(.leading, 10 + CGFloat(depth) * 12)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityLabel("\(layer.label), \(layer.kind.title)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .contextMenu {
            if !isRoot, layer.kind == .frame, model.component == nil {
                Button("Make a Component") { model.selection = layer.id; model.makeComponent() }
            }
            if layer.kind == .instance {
                Button("Edit the Component") { model.editComponent(layer.component) }
                if model.component == nil {
                    Button("Detach") { model.selection = layer.id; model.detachSelected() }
                }
            }
            if !isRoot {
                Button("Move Up") { model.selection = layer.id; model.moveSelected(by: -1) }
                Button("Move Down") { model.selection = layer.id; model.moveSelected(by: 1) }
                Button("Put in a Frame") { model.selection = layer.id; model.wrapSelected() }
                Divider()
                Button("Remove", role: .destructive) { model.selection = layer.id; model.removeSelected() }
            }
        }
    }

    private var icon: String {
        switch layer.kind {
        case .frame: layer.layout.isRow ? "rectangle.split.3x1" : "rectangle.split.1x2"
        case .text: "textformat"
        case .rect: "square"
        case .image: "photo"
        case .instance: "diamond"
        }
    }
}

/// The theme's tokens, by scope: each one's value edited in place, a colour
/// with a well as well as its text.
private struct TokensList: View {
    let model: DesignWorkspaceModel
    let document: DesignDocument

    private var scopes: [(scope: String, tokens: [DesignToken])] {
        var order: [String] = []
        var by: [String: [DesignToken]] = [:]
        for token in document.tokens {
            if by[token.scope] == nil { order.append(token.scope) }
            by[token.scope, default: []].append(token)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        if !document.view.theme.exists {
            Text("This design has no theme.css. Tokens are the custom properties in one — --name: value — and layers refer to them by name.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(14)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(scopes, id: \.scope) { group in
                        Text(group.scope).font(.aeLabel).foregroundStyle(Color.ink2)
                            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                        ForEach(group.tokens) { token in
                            TokenRow(model: model, token: token, resolver: model.resolver)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

private struct TokenRow: View {
    let model: DesignWorkspaceModel
    let token: DesignToken
    let resolver: DesignResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                let color = resolver.kind(of: token) == .color ? resolver.color(token.name) : nil
                if let color {
                    ColorPicker(token.name, selection: Binding(
                        get: { Color(nsColor: color) },
                        set: { model.setToken(token, to: DesignResolver.hex(NSColor($0)), coalescing: true) }
                    ), supportsOpacity: true)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(token.name).font(.aeMono).foregroundStyle(Color.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            CommitField(title: "\(token.name) value", value: token.value) { model.setToken(token, to: $0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Inspector

/// The chosen layer: what it is and what it's in, then only the sections
/// that apply to it; or the page.
private struct DesignInspector: View {
    @Bindable var model: DesignWorkspaceModel
    let document: DesignDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let component = model.component, !component.options.isEmpty {
                HStack(spacing: 8) {
                    Text("Editing").font(.aeSmall).foregroundStyle(Color.ink2).fixedSize()
                    Picker("Editing", selection: Binding(get: { model.variant ?? "" }, set: { model.variant = $0.isEmpty ? nil : $0 })) {
                        Text("As written").tag("")
                        ForEach(component.options, id: \.key) { Text($0.name).tag($0.key) }
                    }
                    // A menu: a component's options and states outgrow a
                    // segmented control in the inspector's width.
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .help("A change made with an option chosen holds for instances that pick it")
            } else if model.component == nil, let page = model.page, page.breakpoints.count > 1 {
                HStack(spacing: 8) {
                    Text("Editing").font(.aeSmall).foregroundStyle(Color.ink2).fixedSize()
                    Picker("Editing", selection: Binding(get: { model.breakpoint ?? page.widestFirst.first?.id ?? "" }, set: { model.breakpoint = $0 })) {
                        ForEach(page.widestFirst) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .help("A change at a narrower breakpoint holds there and narrower; the widest is the page's own")
            }
            if let page = model.pageHere, let layer = model.chosen {
                LayerInspector(model: model, page: page, layer: layer, tokens: document.tokens, resolver: model.resolver)
                    .id(layer.id)
            } else if let component = model.component {
                ComponentInspector(model: model, component: component)
                    .id(component.id)
            } else if let page = model.page {
                PanelSection(page.name) {
                    Text(verbatim: page.breakpoints.map { "\($0.name) \(Int($0.width))" }.joined(separator: " · "))
                        .font(.aeBody).foregroundStyle(Color.ink)
                    Text(verbatim: "\(page.layers.count) layers · \(document.tokens.count) tokens in theme.css")
                        .font(.aeSmall).foregroundStyle(Color.ink2)
                    Text("Click a layer to choose it; double-click text to type into it; Esc chooses the frame it's in. A adds a frame, T text, R a shape, inside the chosen frame; + adds an image. A change made on a narrower artboard holds there and narrower, and its row is marked. Drag the empty canvas or use two fingers to move; pinch or ⌘-scroll to zoom; f shows it all. ⌘/ shows the code.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                SyncSection(model: model, document: document)
                if !document.view.problems.isEmpty {
                    PanelSection("Missing tokens") {
                        ForEach(document.view.problems, id: \.self) { Text($0).font(.aeSmall).foregroundStyle(Color.coral).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }
}

private struct LayerInspector: View {
    let model: DesignWorkspaceModel
    /// The page and the layer as the breakpoint being edited has them.
    let page: DesignPage
    let layer: DesignLayer
    let tokens: [DesignToken]
    let resolver: DesignResolver

    private var parent: DesignLayer? { page.parent(of: layer.id) }
    private var inRow: Bool { parent?.layout.isRow == true }

    /// What the breakpoint being edited says of the field at `keys`.
    private func said(_ keys: [String]) -> Said {
        Said(here: model.says(layer.id, keys), reset: { model.reset(layer.id, keys) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(layer.label) {
                    HStack(spacing: 4) {
                        Text(layer.kind.title).font(.aeBody).foregroundStyle(Color.ink)
                        if let parent {
                            Text("in").font(.aeSmall).foregroundStyle(Color.ink3)
                            Button(parent.label) { model.selection = parent.id }
                                .buttonStyle(.link).font(.aeSmall)
                                .help("Choose the frame it's in (Esc)")
                            Text(verbatim: "· \(parent.layout.isRow ? "row" : "column")\(resolver.length(parent.layout.gap).map { ", gap \(DesignVal.num($0))" } ?? "")")
                                .font(.aeSmall).foregroundStyle(Color.ink3)
                        } else {
                            Text("· the page").font(.aeSmall).foregroundStyle(Color.ink3)
                        }
                    }
                    InspectorRow("Name") {
                        CommitField(title: "Name", value: layer.name, prompt: layer.id) { model.rename(layer.id, to: $0) }
                    }
                }
                if layer.kind == .text {
                    PanelSection("Text") {
                        CommitField(title: "Text", value: layer.text, axis: .vertical, focusRequest: model.editTextRequest) { model.setText(layer.id, $0) }
                            .lineLimit(1...6)
                        TokenPicker(label: "Font", kind: .font, value: layer.style.font, tokens: tokens, resolver: resolver, said: said(["style", "font"])) { model.setStyle(layer.id, "font", to: $0) }
                        TokenPicker(label: "Colour", kind: .color, value: layer.style.color, tokens: tokens, resolver: resolver, said: said(["style", "color"])) { model.setStyle(layer.id, "color", to: $0) }
                        WordPicker(label: "Align", value: layer.style.textAlign ?? "start", options: [("start", "Left"), ("center", "Centre"), ("end", "Right")], said: said(["style", "textAlign"])) {
                            model.setStyle(layer.id, "textAlign", to: $0 == "start" && model.overriding == nil ? nil : $0)
                        }
                    }
                }
                if layer.kind == .image {
                    ImageSection(model: model, layer: layer, said: said)
                }
                if layer.kind == .instance {
                    InstanceSection(model: model, layer: layer)
                }
                if parent != nil {
                    PanelSection("Size") {
                        SizePicker(label: "Width", value: layer.width, said: said(["w"])) { model.setSize(layer.id, width: true, to: $0) }
                        SizePicker(label: "Height", value: layer.height, said: said(["h"])) { model.setSize(layer.id, width: false, to: $0) }
                        if inRow, parent?.layout.wrap == true, layer.width == .fill {
                            InspectorRow("Narrowest", said: said(["minW"])) {
                                CommitField(title: "Narrowest", value: layer.minW.map { DesignVal.num($0).description } ?? "", prompt: "0") {
                                    let t = $0.trimmingCharacters(in: .whitespaces)
                                    model.setNarrowest(layer.id, to: t.isEmpty ? nil : Double(t).map { max(0, $0) })
                                }
                                .frame(width: 60)
                                Text("before it wraps").font(.aeSmall).foregroundStyle(Color.ink3)
                            }
                        }
                        InspectorRow("Shown", said: said(["hidden"])) {
                            Toggle(model.overriding.map { "At \($0.name)" } ?? "Everywhere it isn't hidden", isOn: Binding(get: { !layer.hidden }, set: { model.setHidden(layer.id, !$0) }))
                                .toggleStyle(.checkbox).font(.aeSmall)
                        }
                    }
                }
                if layer.kind == .frame {
                    PanelSection("Layout") {
                        WordPicker(label: "Direction", value: layer.layout.direction ?? "column", options: [("column", "Column"), ("row", "Row")], said: said(["layout", "direction"])) {
                            model.setLayout(layer.id, "direction", to: $0 == "column" && model.overriding == nil ? nil : $0)
                        }
                        if layer.layout.isRow {
                            InspectorRow("Wrap", said: said(["layout", "wrap"])) {
                                Toggle("Wrap onto more lines", isOn: Binding(get: { layer.layout.wrap == true }, set: { model.setLayout(layer.id, "wrap", to: $0 ? true : (model.overriding == nil ? nil : false)) }))
                                    .toggleStyle(.checkbox).font(.aeSmall)
                            }
                        }
                        LengthPicker(label: "Gap", value: layer.layout.gap, tokens: tokens, resolver: resolver, said: said(["layout", "gap"])) { model.setLayout(layer.id, "gap", to: $0?.json) }
                        LengthPicker(label: "Pad H", value: layer.layout.padH, tokens: tokens, resolver: resolver, said: said(["layout", "padH"])) { model.setLayout(layer.id, "padH", to: $0?.json) }
                        LengthPicker(label: "Pad V", value: layer.layout.padV, tokens: tokens, resolver: resolver, said: said(["layout", "padV"])) { model.setLayout(layer.id, "padV", to: $0?.json) }
                        WordPicker(label: "Align", value: layer.layout.align ?? "start", options: [("start", "Start"), ("center", "Centre"), ("end", "End")], said: said(["layout", "align"])) {
                            model.setLayout(layer.id, "align", to: $0 == "start" && model.overriding == nil ? nil : $0)
                        }
                        WordPicker(label: "Justify", value: layer.layout.justify ?? "start", options: [("start", "Start"), ("center", "Centre"), ("end", "End"), ("between", "Apart")], said: said(["layout", "justify"])) {
                            model.setLayout(layer.id, "justify", to: $0 == "start" && model.overriding == nil ? nil : $0)
                        }
                    }
                }
                if layer.kind != .text, layer.kind != .instance {
                    PanelSection("Style") {
                        if layer.kind != .image {
                            TokenPicker(label: "Fill", kind: .color, value: layer.style.fill, tokens: tokens, resolver: resolver, said: said(["style", "fill"])) { model.setStyle(layer.id, "fill", to: $0) }
                        }
                        TokenPicker(label: "Stroke", kind: .color, value: layer.style.stroke, tokens: tokens, resolver: resolver, said: said(["style", "stroke"])) { model.setStyle(layer.id, "stroke", to: $0) }
                        LengthPicker(label: "Radius", value: layer.style.radius, tokens: tokens, resolver: resolver, said: said(["style", "radius"])) { model.setStyle(layer.id, "radius", to: $0?.json) }
                    }
                }
                if parent != nil {
                    HStack {
                        Spacer()
                        Button("Remove", role: .destructive, action: model.removeSelected).controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

/// The folder of HTML and CSS the design is kept in step with: where it is,
/// a way to choose or type another, and what the last file read back
/// couldn't take.
private struct SyncSection: View {
    let model: DesignWorkspaceModel
    let document: DesignDocument

    var body: some View {
        PanelSection("Sync") {
            if let folder = model.syncFolder {
                Text(verbatim: folder.path(percentEncoded: false)).font(.aeMono).foregroundStyle(Color.ink).lineLimit(2).truncationMode(.head)
                    .help(folder.path(percentEncoded: false))
                Text("Each component and page is written here as HTML and CSS on every save. Edit a colour, a font, padding or words there and it comes back as a step.")
                    .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Button("Write Now") { model.keepInStep(with: folder) }
                    Spacer(minLength: 0)
                    Button("Stop") { model.keepInStep(with: nil) }
                }
                .buttonStyle(.borderless).font(.aeSmall)
                ForEach(model.syncNotes, id: \.self) { note in
                    Text(note).font(.aeSmall).foregroundStyle(Color.amber).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Keep the design in step with a folder of HTML and CSS — a project's src/components — written on every save and read back when edited there.")
                    .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose a Folder…", action: model.chooseSyncFolder)
                        .buttonStyle(.borderless).font(.aeSmall)
                    Spacer(minLength: 0)
                }
                InspectorRow("Or a path") {
                    CommitField(title: "Sync folder path", value: "", prompt: "src/components") { typed in
                        let path = typed.trimmingCharacters(in: .whitespaces)
                        guard !path.isEmpty else { return }
                        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : document.url.appending(path: path)
                        model.keepInStep(with: url)
                    }
                }
            }
        }
    }
}

/// An instance: its component, the option it picks of each prop, its words
/// for the component's text, and the way to the component.
private struct InstanceSection: View {
    let model: DesignWorkspaceModel
    let layer: DesignLayer

    var body: some View {
        if let component = model.document?.component(layer.component) {
            PanelSection("Component") {
                HStack(spacing: 4) {
                    Image(systemName: "diamond").font(.system(size: 10)).foregroundStyle(Color.lavender)
                    Text(verbatim: "Instance of \(component.name)").font(.aeBody).foregroundStyle(Color.ink)
                    Spacer(minLength: 0)
                    Button("Edit Component") { model.editComponent(component.id) }.buttonStyle(.borderless).font(.aeSmall)
                }
                ForEach(component.props) { prop in
                    WordPicker(label: prop.name.prefix(1).uppercased() + prop.name.dropFirst(), value: layer.props[prop.name] ?? prop.defaultOption, options: prop.options.map { ($0, $0) }) {
                        model.setProp(layer.id, prop.name, to: $0 == prop.defaultOption ? nil : $0)
                    }
                }
                if component.states.contains("disabled") {
                    InspectorRow("Disabled") {
                        Toggle("Shown as disabled, and said so", isOn: Binding(get: { layer.props["state"] == "disabled" }, set: { model.setDisabled(layer.id, $0) }))
                            .toggleStyle(.checkbox).font(.aeSmall)
                    }
                }
                ForEach(component.textLayers) { text in
                    InspectorRow(text.label) {
                        CommitField(title: "\(text.label) words", value: layer.texts[text.id] ?? "", prompt: text.text) { model.setWords(layer.id, for: text.id, to: $0) }
                    }
                }
                let uses = model.uses(of: component.id)
                HStack {
                    Text(verbatim: "Used \(uses.count) time\(uses.count == 1 ? "" : "s") in the design").font(.aeSmall).foregroundStyle(Color.ink3)
                    Spacer(minLength: 0)
                    if model.component == nil {
                        Button("Detach") { model.detachSelected() }.buttonStyle(.borderless).font(.aeSmall)
                            .help("Make it plain layers, as it looks now, no longer following \(component.name)")
                    }
                }
            }
        } else {
            PanelSection("Component") {
                Text(verbatim: "Places \(layer.component), which isn't one of the design's components.").font(.aeSmall).foregroundStyle(Color.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The component being edited, with nothing chosen: its name, its props
/// and their options, and where it's used.
private struct ComponentInspector: View {
    let model: DesignWorkspaceModel
    let component: DesignComponent

    private var props: [(name: String, options: [String])] { component.props.map { ($0.name, $0.options) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(component.name) {
                    InspectorRow("Name") {
                        CommitField(title: "Name", value: component.name) { model.renameComponent($0) }
                    }
                    Text("Changes here change every page that places it. Choose an option's artboard to say what that option changes.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("Props") {
                    ForEach(Array(component.props.enumerated()), id: \.offset) { i, prop in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                CommitField(title: "Prop name", value: prop.name) { name in
                                    var next = props
                                    next[i].name = name.trimmingCharacters(in: .whitespaces)
                                    model.setProps(next)
                                }
                                .frame(width: 100)
                                Spacer(minLength: 0)
                                Button("Remove") { model.setProps(props.enumerated().filter { $0.offset != i }.map(\.element)) }
                                    .buttonStyle(.borderless).font(.aeSmall)
                            }
                            CommitField(title: "\(prop.name) options", value: prop.options.joined(separator: ", "), prompt: "primary, secondary") { text in
                                var next = props
                                next[i].options = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                model.setProps(next)
                            }
                        }
                    }
                    Button("Add a Prop") {
                        var name = "variant"
                        var n = 2
                        while props.contains(where: { $0.name == name }) { name = "prop\(n)"; n += 1 }
                        model.setProps(props + [(name, ["one", "two"])])
                    }
                    .buttonStyle(.borderless).font(.aeSmall)
                    Text("The first option is the default. An option a page picks can't be taken away while it's picked.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("States") {
                    ForEach(DesignComponent.allStates, id: \.self) { state in
                        Toggle(state.prefix(1).uppercased() + state.dropFirst(), isOn: Binding(
                            get: { component.states.contains(state) },
                            set: { on in model.setStates(on ? component.states + [state] : component.states.filter { $0 != state }) }
                        ))
                        .toggleStyle(.checkbox).font(.aeSmall)
                    }
                    Text("Each has an artboard of its own. Hover, focus and pressed are how someone uses the page; a page can make an instance disabled.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("Used in") {
                    let uses = model.uses(of: component.id)
                    if uses.isEmpty {
                        Text("No page places it yet: + ▸ Component on a page.").font(.aeSmall).foregroundStyle(Color.ink3)
                    }
                    ForEach(uses, id: \.self) { use in
                        Button {
                            model.show(use)
                        } label: {
                            Text(verbatim: "\(model.place(of: use)) · \(model.document?.page(use.page)?.layer(use.layer)?.label ?? use.layer)")
                        }
                        .buttonStyle(.link).font(.aeSmall)
                    }
                }
            }
        }
    }
}

/// An image layer: its picture, what it follows, how it fills its layer and
/// what it says to someone who can't see it.
private struct ImageSection: View {
    let model: DesignWorkspaceModel
    let layer: DesignLayer
    let said: ([String]) -> Said

    var body: some View {
        PanelSection("Image") {
            InspectorRow("Picture") {
                Text(verbatim: layer.src.replacingOccurrences(of: "images/", with: "")).font(.aeSmall).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                Button("Replace…") { model.chooseImageFile(replacing: layer.id) }.buttonStyle(.borderless).font(.aeSmall)
            }
            if let link = model.link(for: layer.id), let asset = model.project?.asset(link.asset) {
                LinkRow(model: model, link: link, asset: asset)
            }
            WordPicker(label: "Fit", value: layer.style.fit ?? "cover", options: [("cover", "Fill"), ("contain", "Fit")], said: said(["style", "fit"])) {
                model.setStyle(layer.id, "fit", to: $0 == "cover" && model.overriding == nil ? nil : $0)
            }
            InspectorRow("Says") {
                CommitField(title: "What the picture shows, for someone who can't see it", value: layer.text, prompt: "What it shows") { model.setText(layer.id, $0) }
            }
        }
    }
}

/// What an image follows: a live dot (mint follows the newest, grey keeps
/// a version), the asset and its workspace, the version, and the way out.
private struct LinkRow: View {
    let model: DesignWorkspaceModel
    let link: AssetLink
    let asset: Asset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(link.pinned == nil ? Color.live : Color.ink3).frame(width: 7, height: 7)
                    .accessibilityLabel(link.pinned == nil ? "Live" : "Kept")
                Text(verbatim: "\(asset.name) · \(asset.source.title)").font(.aeSmall).foregroundStyle(Color.ink).lineLimit(1)
                Spacer(minLength: 0)
                Picker("Version", selection: Binding(get: { link.pinned ?? 0 }, set: { model.keep($0 == 0 ? nil : $0, for: link) })) {
                    Text("Newest").tag(0)
                    ForEach(asset.versions.reversed(), id: \.number) { Text(verbatim: "v\($0.number)").tag($0.number) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            HStack {
                Button("Show the Source") { model.showSource?(asset) }.buttonStyle(.borderless).font(.aeSmall)
                Button("Unlink") { model.unlink(link) }.buttonStyle(.borderless).font(.aeSmall)
                    .help("The picture stays, and stops following \(asset.name)")
            }
        }
    }
}

// MARK: - Bars

private struct DesignStatusBar: View {
    let model: DesignWorkspaceModel
    let document: DesignDocument

    var body: some View {
        HStack(spacing: 10) {
            Button { model.close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink2)
            .help("Back to the designs")
            .accessibilityLabel("Back to the designs")
            Text(document.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi)
            if let pageID = model.pageID, let page = document.page(pageID) {
                Divider().frame(height: 12)
                Button(page.name) { model.closeComponent() }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(model.component == nil ? Color.ink : Color.ink2)
                    .disabled(model.component == nil)
            }
            if let component = model.component {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.ink3)
                Image(systemName: "diamond").font(.system(size: 9)).foregroundStyle(Color.lavender)
                Text(component.name).font(.system(size: 11.5)).foregroundStyle(Color.inkHi)
            }
            if !document.unsaved.isEmpty {
                Divider().frame(height: 12)
                Button("Save  ⌘S", action: model.saveNow).controlSize(.small)
                    .help(document.unsaved.joined(separator: ", "))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .aeGlass(.floating, radius: 9)
    }
}

private struct DesignDock: View {
    @Bindable var model: DesignWorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton("rectangle.split.1x2", label: "Add a frame (A)") { model.add(.frame) }
            IconButton("textformat", label: "Add text (T)") { model.add(.text) }
            IconButton("square", label: "Add a shape (R)") { model.add(.rect) }
            IconButton("photo", label: "Add an image from a file") { model.chooseImageFile() }
            Divider().frame(height: 20).padding(.horizontal, 4)
            IconButton("chevron.left.forwardslash.chevron.right", label: "Code (⌘/)", isOn: model.codeOpen) { model.codeOpen.toggle() }
            IconButton("arrow.up.left.and.arrow.down.right", label: "Show every artboard (f)", action: model.fit)
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
}

/// The chosen layer as the HTML and CSS it's written as: shown, not hidden.
private struct CodeDrawer: View {
    let model: DesignWorkspaceModel

    var body: some View {
        let code = model.code
        HStack(alignment: .top, spacing: 0) {
            pane("HTML", code?.html ?? "")
            Rectangle().fill(Color.line2).frame(width: 1)
            pane("CSS", code?.css ?? "")
        }
        .frame(maxWidth: 980)
        .frame(height: 200)
        .aeGlass(.floating, radius: 12)
    }

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.aeLabel).foregroundStyle(Color.ink2)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless).font(.aeSmall)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text)
                    .font(.aeMono)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesignNotice: View {
    let text: String
    /// Saying something went well, not warning.
    let good: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(good ? Color.live : Color.amber)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.inkHi).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink2)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .aeGlass(.floating, radius: 10)
        .padding(.bottom, 4)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}
