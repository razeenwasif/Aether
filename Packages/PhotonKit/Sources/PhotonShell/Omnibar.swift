import PhotonDesign
import PhotonGraph
import AppKit
import CanvasUI
import DiffuseCore
import ModelCore
import ModelUI
import SwiftUI

extension AppModel {
    /// ⌘K: the omnibar open with what applies now, or shut.
    public func toggleOmnibar() {
        guard !omnibar.isOpen else { return omnibar.close() }
        omnibar.open(with: omnibarItems)
        // Flows saved since are read in the background, and offered once in.
        Task {
            await refreshFlowFiles()
            if omnibar.isOpen { omnibar.offer(omnibarItems) }
        }
    }

    /// Everything the omnibar offers now: the workspace's own first, then
    /// actions, the project's assets, and places to go.
    public var omnibarItems: [OmniItem] {
        here + actions + assetItems + goTo
    }

    private var here: [OmniItem] {
        switch active {
        case .canvas where canvas.document != nil: canvasItems
        case .canvas: [OmniItem(.here, "New Canvas…", detail: "⌘N") { self.canvas.askForNew() }]
        case .diffuse: diffuseItems
        case .model where modeling.document != nil: modelItems
        case .model: [OmniItem(.here, "New Scene…", detail: "⌘N") { self.modeling.askForNew() }]
        default: []
        }
    }

    private var canvasItems: [OmniItem] {
        let c = canvas
        var items = CanvasTool.allCases.map { tool in
            OmniItem(.here, tool.title, detail: tool.key.isEmpty ? "Tool" : "Tool · \(tool.key)") { c.tool = tool }
        }
        items += [
            OmniItem(.here, "Add a Layer", detail: "⇧⌘N") { c.addLayer() },
            OmniItem(.here, "Remove the Layer") { c.removeLayer() },
            OmniItem(.here, "New Frame") { c.addFrame() },
            OmniItem(.here, "Copy the Frame", detail: "⇧N") { c.copyFrame() },
            OmniItem(.here, c.playing ? "Stop Playing" : "Play the Frames", detail: "↩") { c.togglePlaying() },
            OmniItem(.here, c.onionOn ? "Hide the Onion Skin" : "Show the Onion Skin", detail: "⇧O") { c.onionOn.toggle() },
            OmniItem(.here, c.showGrid ? "Hide the Pixel Grid" : "Show the Pixel Grid", detail: "⇧G") { c.showGrid.toggle() },
            OmniItem(.here, "Draw Mirrored Across", detail: "m") { c.mirrorAcross.toggle() },
            OmniItem(.here, "Free Transform", detail: "⌘T") { c.startTransform(free: true) },
            OmniItem(.here, "Select All", detail: "⌘A") { c.selectAll() },
            OmniItem(.here, "Select Nothing", detail: "⌘D") { c.selectNothing() },
            OmniItem(.here, "Crop to the Selection") { c.cropToSelection() },
            OmniItem(.here, "Turn Right") { c.turn(quarters: 1) },
            OmniItem(.here, "Turn Left") { c.turn(quarters: 3) },
            OmniItem(.here, "Mirror Across") { c.mirror(across: true) },
            OmniItem(.here, "Resize…") { c.askingToResize = true },
            OmniItem(.here, "Grow ×2", detail: "Scale2x, edges kept crisp") { c.grow(by: 2) },
            OmniItem(.here, "Grow ×3", detail: "Scale3x") { c.grow(by: 3) },
            OmniItem(.here, "Fit in View", detail: "f") { c.fit() },
            OmniItem(.here, "Export…", detail: "PNG, sprite sheet or Photoshop · ⌘E") { c.exportPNG() },
            OmniItem(.here, "Publish as an Asset", detail: "for other canvases and flows to follow") { c.publishAsAsset() },
        ]
        return items
    }

    private var modelItems: [OmniItem] {
        let m = modeling
        if let edit = m.editing {
            return EditPart.allCases.map { part in
                OmniItem(.here, "Choose \(part.title)", detail: part.key) { m.showPart(part) }
            } + [
                OmniItem(.here, "Extrude", detail: "e") { m.extrudeChosen() },
                OmniItem(.here, "Inset", detail: "i") { m.insetChosen() },
                OmniItem(.here, "Bevel", detail: "b") { m.bevelChosen() },
                OmniItem(.here, "Loop Cut", detail: "⌘R") { m.loopCutChosen() },
                OmniItem(.here, "Delete", detail: "⌫") { m.deleteChosen() },
                OmniItem(.here, "Choose Everything", detail: "a") { edit.chooseAll() },
                OmniItem(.here, "Frame What’s Chosen", detail: "f") { m.frameSelected() },
                OmniItem(.here, "Back to the Objects", detail: "⇥") { m.exitEdit() },
            ]
        }
        var items = SceneAddition.allCases.map { addition in
            OmniItem(.here, "Add \(addition == .empty ? "an Empty" : "a \(addition.title)")", detail: addition.isMesh ? "Mesh" : nil) { m.add(addition) }
        }
        items += [
            OmniItem(.here, "Frame the Object", detail: "f") { m.frameSelected() },
            OmniItem(.here, "Frame Everything") { m.frameAll() },
        ]
        if let node = m.selectedNode, node.kind == "mesh" {
            items += ["mirror", "array", "subdivide"].map { kind in
                OmniItem(.here, "Add \(kind.capitalized) to \(node.name)", detail: "Modifier") { m.addModifier(kind, to: node.id) }
            }
            items.append(OmniItem(.here, "Choose a Mesh for \(node.name)…", detail: ".obj") { m.chooseMesh(for: node.id) })
            items.append(OmniItem(.here, "Edit \(node.name)’s Mesh", detail: "⇥") { m.enterEdit() })
            items.append(OmniItem(.here, "New Material for \(node.name)", detail: "Material") { m.newMaterial() })
            items += LayerPattern.allCases.map { pattern in
                OmniItem(.here, "Add a \(pattern.title) Layer to \(node.name)", detail: "Material") { m.addLayer(pattern) }
            }
        }
        items.insert(OmniItem(.here, "Render", detail: "⌘↩") { m.render() }, at: 0)
        items.append(OmniItem(.here, m.renderOpen ? "Hide the Render" : "Show the Render", detail: "Render") { m.toggleRenderDrawer() })
        items.append(OmniItem(.here, m.graphOpen ? "Hide the Material Graph" : "Show the Material Graph", detail: "Material") { m.toggleGraph() })
        if !m.unwornMaterials.isEmpty {
            items.append(OmniItem(.here, "Remove Unworn Materials", detail: "\(m.unwornMaterials.count)") { m.removeUnwornMaterials() })
        }
        items.append(OmniItem(.here, "All Scenes") { m.close() })
        return items
    }

    private var diffuseItems: [OmniItem] {
        let d = diffuse
        var items = [
            OmniItem(.here, "Generate", detail: "⌘↩") { d.run() },
            OmniItem(.here, d.stage == .graph ? "Show the Gallery" : "Show the Graph", detail: "⇧⌘G") { d.toggleStage() },
            OmniItem(.here, "Fit the Flow in View", detail: "⇧1") { d.fitToView() },
        ]
        // Every node there is to add: shown once something is typed.
        if d.editor != nil {
            items += d.library.catalogue.nodes.map { node in
                OmniItem(.here, "Add \(node.title)", detail: node.group, onlyWhenAsked: true, id: "node:\(node.type)") {
                    d.show(.graph)
                    d.addNode(node.type)
                }
            }
        }
        return items
    }

    private var actions: [OmniItem] {
        [
            OmniItem(.actions, "New Canvas…") {
                self.active = .canvas
                self.canvas.askForNew()
            },
            OmniItem(.actions, "New Scene…") {
                self.active = .model
                self.modeling.askForNew()
            },
            OmniItem(.actions, "New Flow") {
                self.active = .diffuse
                self.diffuse.newFlow(template: nil)
            },
            OmniItem(.actions, "Save", detail: "⌘S") {
                switch self.active {
                case .canvas: self.canvas.save()
                case .model: self.modeling.saveNow()
                default: self.diffuse.save()
                }
            },
            OmniItem(.actions, "Show or Hide the Inspector", detail: "⌘\\") { self.toggleInspector() },
            OmniItem(.actions, "Show or Hide the Navigator", detail: "⌘0") { self.toggleNavigator() },
        ]
    }

    /// The project's assets, each doing what fits the workspace on screen:
    /// placed as a layer in a canvas, taken by a Load Image in a flow,
    /// placed as an image in a design, or opened where it's made.
    private var assetItems: [OmniItem] {
        project.assets.map { asset in
            let version = asset.newest.map { " v\($0.number)" } ?? ""
            let (verb, run): (String, @MainActor () -> Void) = switch active {
            case .canvas where canvas.document != nil && asset.document != canvas.documentPath:
                ("Place as a layer", { self.canvas.place(asset) })
            case .diffuse where diffuse.editor != nil:
                ("Use in a Load Image", { Task { await self.diffuse.use(asset) } })
            case .design where design.page != nil && asset.newest != nil:
                ("Place as an image", { self.design.addImage(from: asset) })
            default:
                ("Open", { self.showSource(asset) })
            }
            return OmniItem(.assets, asset.name, detail: "\(verb) · \(asset.source.title)\(version)", live: true, id: "asset:\(asset.id)", run: run)
        }
    }

    private var goTo: [OmniItem] {
        var items = Workspace.allCases.map { workspace in
            OmniItem(.goTo, workspace.title, detail: "⌘\(workspace.shortcut.character)") { self.active = workspace }
        }
        items += canvas.canvases.map { file in
            OmniItem(.goTo, file.name, detail: "Canvas", id: "canvas:\(file.url.path)") {
                self.active = .canvas
                self.canvas.open(file.url)
            }
        }
        items += modeling.scenes.map { file in
            OmniItem(.goTo, file.name, detail: "Scene", id: "scene:\(file.url.path)") {
                self.active = .model
                self.modeling.open(file.url)
            }
        }
        items += flowFiles.map { url in
            OmniItem(.goTo, url.lastPathComponent.replacingOccurrences(of: ".flow.json", with: ""), detail: "Flow", id: "flow:\(url.path)") {
                self.active = .diffuse
                self.diffuse.openFlow(at: url)
            }
        }
        items.append(OmniItem(.goTo, "The Gallery", detail: "Diffuse") {
            self.active = .diffuse
            self.diffuse.show(.gallery)
        })
        return items
    }
}

/// The omnibar: a field and the list under it, floating centre-top.
struct Omnibar: View {
    @Bindable var model: AppModel
    @Bindable var omnibar: OmnibarModel
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    var body: some View {
        let items = omnibar.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2)
                TextField("Tools, actions, assets, go to…", text: $omnibar.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.inkHi)
                    .focused($focused)
                    .accessibilityLabel("Search tools, actions, assets and places")
                Button(omnibar.scope.title) { omnibar.cycleScope() }
                    .buttonStyle(.plain)
                    .font(.aeSmall)
                    .foregroundStyle(omnibar.scope == .all ? Color.ink2 : Color.ice)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.surfacePill))
                    .help("⇥ narrows the list to one group")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.raise1))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            if items.isEmpty {
                Text("Nothing matches “\(omnibar.query)”").font(.aeBody).foregroundStyle(Color.ink2).frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].group != item.group {
                                    Text(item.group.rawValue).font(.aeLabel).foregroundStyle(Color.ink3)
                                        .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 3)
                                }
                                // A button, so a click, VoiceOver and Press all run it.
                                Button { run(item) } label: { row(item, selected: omnibar.choosing && index == omnibar.selected) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: omnibar.selected) {
                        if items.indices.contains(omnibar.selected) { scroller.scrollTo(items[omnibar.selected].id) }
                    }
                }
            }
            Text("Type, or ↑↓ to choose · ↩ run · ⇥ \(omnibar.scope == .all ? "narrow" : "next group") · esc close")
                .font(.aeSmall).foregroundStyle(Color.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).frame(height: 28)
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .aeGlass(.floating)
        .onAppear {
            focused = true
            // Again on the next turn: the first time, the graph or canvas may
            // still hold the keys.
            DispatchQueue.main.async { focused = true }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handle(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private func row(_ item: OmniItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if item.live {
                Circle().fill(Color.live).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(item.title).font(.aeBody).foregroundStyle(Color.inkHi).lineLimit(1)
            Spacer(minLength: 12)
            if let detail = item.detail {
                Text(detail).font(.aeSmall).foregroundStyle(Color.ink2).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.button).fill(selected ? Color.raise2 : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The omnibar's own keys: ↑↓ choose, ↩ runs, ⇥ narrows, esc closes.
    private func handle(_ event: NSEvent) -> Bool {
        guard omnibar.isOpen else { return false }
        let count = omnibar.results.count
        switch event.keyCode {
        case 126: omnibar.move(by: -1, in: count)
        case 125: omnibar.move(by: 1, in: count)
        case 48: omnibar.cycleScope(back: event.modifierFlags.contains(.shift))
        case 53: omnibar.close()
        case 36, 76:
            let items = omnibar.results
            if omnibar.choosing, items.indices.contains(omnibar.selected) { run(items[omnibar.selected]) }
        default: return false
        }
        return true
    }

    private func run(_ item: OmniItem) {
        omnibar.close()
        item.run()
    }
}
