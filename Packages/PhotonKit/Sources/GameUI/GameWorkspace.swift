import PhotonDesign
import AppKit
import GameCore
import SwiftUI
import UniformTypeIdentifiers

/// The Game workspace: with a game open, its room on the stage edge to
/// edge, its rooms and what's in them floating on the left, what's selected
/// on the right, and Play in the same stage; with none, the games.
public struct GameWorkspace: View {
    @Bindable var model: GameWorkspaceModel

    public init(model: GameWorkspaceModel) {
        self.model = model
    }

    private var leftInset: CGFloat { model.navigatorOpen && model.document != nil && !model.playing ? 264 : 0 }
    private var rightInset: CGFloat { model.inspectorOpen && model.document != nil && !model.playing ? 300 : 0 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let document = model.document {
                GameStage(model: model, revision: document.revision, roomID: model.roomID, selection: model.selection, playing: model.playing, fitRequest: model.fitRequest,
                          insets: (model.navigatorOpen ? 264 : 0, model.inspectorOpen ? 300 : 0), tool: model.tool, finish: model.finishInEditor)
                HStack(alignment: .top, spacing: 0) {
                    GameNavigator(model: model, document: document)
                        .frame(width: 248)
                        .padding(8)
                        .sliding(open: model.navigatorOpen && !model.playing, from: .leading, by: 264)
                    Spacer(minLength: 0)
                    GameInspector(model: model, document: document)
                        .frame(width: 284)
                        .padding(8)
                        .sliding(open: model.inspectorOpen && !model.playing, from: .trailing, by: 300)
                }
                GameStatusBar(model: model, document: document)
                    .padding(.leading, 12)
                    .offset(x: leftInset)
                    .padding(.top, 12)
            } else {
                GameHome(model: model)
            }
            VStack(spacing: 10) {
                Spacer()
                if let notice = model.notice {
                    GameNotice(text: notice, good: model.noticeIsGood) { model.notice = nil }
                }
                if model.playing {
                    PlayHUD(model: model).padding(.bottom, 16)
                } else if model.document != nil {
                    GameDock(model: model).padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .centred(between: leftInset, and: rightInset)
        }
        .animation(Motion.panel, value: model.navigatorOpen)
        .animation(Motion.panel, value: model.inspectorOpen)
        .animation(Motion.panel, value: model.playing)
        .background(Color.obsidian0)
    }
}

// MARK: - Home

private struct GameHome: View {
    @Bindable var model: GameWorkspaceModel

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Games").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.inkHi)
                if model.games.isEmpty {
                    Text("No game here yet. A game is a folder of JSON a diff can read — game.json, world.json, a file a room and a prefab — and its art, in Proton's format, so either app opens it.")
                        .font(.aeBody).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(model.games) { game in
                                Button { model.open(game.url) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Image(systemName: "gamecontroller").font(.system(size: 34, weight: .light)).foregroundStyle(Color.ink2)
                                            .frame(maxWidth: .infinity, minHeight: 96)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.raise1))
                                        Text(game.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                                        Text(verbatim: "\(game.rooms) room\(game.rooms == 1 ? "" : "s")").font(.aeSmall).foregroundStyle(Color.ink2)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.raise1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(game.name)")
                            }
                        }
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("New game").font(.aeTitle).foregroundStyle(Color.inkHi)
                TextField("Name", text: $model.newName, prompt: Text("Lumen"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.create)
                Picker("Kind", selection: $model.newKind) {
                    Text("Side-on").tag("metroidvania")
                    Text("Isometric").tag("isometric")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(model.newKind == "isometric"
                    ? "Isometric, seen from above at an angle: a courtyard to walk in eight ways, with a pit, a pillar to walk behind and a crawler, their art drawn in code."
                    : "A Metroidvania from Proton's template: two rooms, a player, a crawler, a bench and a gate, their art drawn in code.")
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

/// The game's rooms, and the things in the room on screen.
private struct GameNavigator: View {
    @Bindable var model: GameWorkspaceModel
    let document: GameDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rooms").font(.aeLabel).foregroundStyle(Color.ink2)
                Spacer()
                Button("Import Art…", action: chooseArt)
                    .buttonStyle(.borderless).font(.aeSmall)
                    .help("Bring in a painter's .psd or a .png as planes of this room, or an Aseprite file or a sprite sheet as an animation. Dropping files on the room does the same.")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ForEach(document.view.rooms) { room in
                row(room.id, detail: Self.size(room.size), dirty: room.dirty, chosen: room.id == model.roomID) {
                    model.roomID = room.id
                }
            }
            if let room = model.room {
                HStack {
                    Text("Entities").font(.aeLabel).foregroundStyle(Color.ink2)
                    Spacer()
                    Text(verbatim: "\(room.entities.count)").font(.aeMono).foregroundStyle(Color.ink3)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(room.entities) { entity in
                            row(entity.id, detail: document.view.prefab(entity.prefab)?.name ?? entity.prefab, dirty: false, chosen: model.selection == .entity(entity.id)) {
                                model.selection = .entity(entity.id)
                            }
                        }
                        ForEach(room.lights) { light in
                            row(light.id, detail: "light", dirty: false, chosen: model.selection == .light(light.id)) { model.selection = .light(light.id) }
                        }
                        ForEach(room.spawns) { spawn in
                            row("spawn \(spawn.id)", detail: "spawn", dirty: false, chosen: model.selection == .spawn(spawn.id)) { model.selection = .spawn(spawn.id) }
                        }
                    }
                }
                HStack {
                    Text("Place").font(.aeLabel).foregroundStyle(Color.ink2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .help("Choose one, then click in the room where it goes")
                ForEach(model.placeable, id: \.id) { kind in
                    row(kind.name, detail: kind.id, dirty: false, chosen: model.tool == .place(kind.id)) {
                        model.tool = model.tool == .place(kind.id) ? .select : .place(kind.id)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }

    private static func size(_ size: [Int]) -> String {
        "\(size.first ?? 0) × \(size.count > 1 ? size[1] : 0)"
    }

    /// Files chosen to bring in.
    private func chooseArt() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = GameWorkspaceModel.importable.compactMap { UTType(filenameExtension: $0) }
        panel.message = "A .psd's groups become planes at the depth their names give in brackets, as in Far hills [800], [play] or [still]."
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls)
    }

    private func row(_ title: String, detail: String, dirty: Bool, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.aeBody).foregroundStyle(chosen ? Color.inkHi : Color.ink).lineLimit(1)
                if dirty { Circle().fill(Color.amber).frame(width: 5, height: 5).accessibilityLabel("unsaved") }
                Spacer(minLength: 4)
                Text(detail).font(.aeSmall).foregroundStyle(Color.ink3).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.raise2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityLabel(title)
    }
}

// MARK: - Inspector

/// The thing selected: what it is, and where it is; or the room.
private struct GameInspector: View {
    @Bindable var model: GameWorkspaceModel
    let document: GameDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case let .shape(id) = model.selection, let line = model.room?.shape(id) {
                ShapeInspector(model: model, line: line)
            } else if case let .light(id) = model.selection, let light = model.room?.light(id) {
                LightInspector(model: model, light: light)
            } else if case let .spawn(id) = model.selection, let spawn = model.room?.spawn(id) {
                PanelSection("Spawn \(spawn.id)") {
                    Text(id == "start" ? "Where a run starts." : "Where the player arrives through a door that names it.").font(.aeSmall).foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "At \(spawn.at.first ?? 0), \(spawn.at.count > 1 ? spawn.at[1] : 0)").font(.aeMono).foregroundStyle(Color.ink)
                    HStack { Spacer(); Button("Remove", role: .destructive, action: model.removeSelected).controlSize(.small) }
                }
            } else if let id = model.selected, let entity = model.room?.entity(id) {
                PanelSection(entity.id) {
                    Text(document.view.prefab(entity.prefab)?.name ?? kindTitle(entity.prefab)).font(.aeBody).foregroundStyle(Color.ink)
                    placeRow(entity)
                    if let r = entity.rect, r.count == 4 {
                        Text(verbatim: "Covers \(r[2]) × \(r[3])").font(.aeSmall).foregroundStyle(Color.ink2)
                    }
                    if let to = entity.to {
                        Text(verbatim: "Leads to \(to.room), at \(to.entry)").font(.aeSmall).foregroundStyle(Color.ink2)
                    }
                    if !entity.requires.isEmpty {
                        Text(verbatim: "Opens with \(entity.requires.joined(separator: ", "))").font(.aeSmall).foregroundStyle(Color.ink2)
                    }
                    if let grants = entity.grants {
                        Text(verbatim: "Gives \(grants)").font(.aeSmall).foregroundStyle(Color.ink2)
                    }
                    HStack {
                        Spacer()
                        Button("Remove", role: .destructive, action: model.removeSelected).controlSize(.small)
                    }
                }
            } else if let room = model.room {
                PanelSection(room.id) {
                    Text(verbatim: "\(Int(room.width)) × \(Int(room.height)) pixels").font(.aeBody).foregroundStyle(Color.ink)
                    Text(verbatim: "\(room.planes.count) planes · \(room.collision.count) lines of collision · \(room.entities.count) things · \(room.spawns.count) spawns")
                        .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    Text("Click anything to choose it, drag it to move it. p draws collision a click a point (double-click or ↩ ends it); on a chosen line drag its points, ⌥-click adds one, double-click takes one out. l places a light. Drag nothing or use two fingers to move over the room; pinch or ⌘-scroll to zoom; f shows it all.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PanelSection("Planes") {
                            Text("Depth behind the play plane, in pixels: further moves slower, below 0 rushes past in front. Lit planes take the room's lights.")
                                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                            ForEach(room.planes) { plane in planeRow(plane) }
                        }
                        PanelSection("Air") {
                            Text("Particles that hang in the room, on a plane: they drift in Play, held still here.")
                                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(room.particles.enumerated()), id: \.offset) { i, emitter in
                                HStack {
                                    Text(emitter.preset.capitalized).font(.aeSmall).foregroundStyle(Color.ink)
                                    Text(verbatim: "on \(room.planes.first { $0.id == emitter.plane }?.name ?? emitter.plane)").font(.aeSmall).foregroundStyle(Color.ink3)
                                    Spacer()
                                    Button("Take Out") { model.setAir(room.particles.enumerated().filter { $0.offset != i }.map(\.element)) }
                                        .buttonStyle(.borderless).font(.aeSmall)
                                }
                            }
                            Menu("Add Air") {
                                ForEach(GameFX.presets, id: \.self) { preset in
                                    Menu(preset.capitalized) {
                                        ForEach(room.planes) { plane in
                                            Button(plane.name.isEmpty ? plane.id : plane.name) {
                                                model.setAir(room.particles + [GameEmitter(preset: preset, plane: plane.id)])
                                            }
                                        }
                                    }
                                }
                            }
                            .controlSize(.small).fixedSize()
                        }
                        PanelSection("Bringing art in") {
                            Text("Import Art… or drop files on the room. A .psd's groups become planes at the depth in their names' brackets, as in Far hills [800]; [play] joins the play plane, [still] doesn't move. An Aseprite file or a sprite sheet becomes an animation.")
                                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Scale").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                                Picker("Scale", selection: $model.importScale) {
                                    ForEach([0.5, 1, 2, 3, 4], id: \.self) { Text(verbatim: "×\($0.formatted())").tag($0) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                                Spacer(minLength: 0)
                            }
                            Toggle("Normal maps for lights", isOn: $model.importNormals).toggleStyle(.checkbox).font(.aeSmall)
                        }
                        PanelSection("Looks") {
                            Text("What each prefab is drawn as: a picture, an animation or a skeleton in the game's art.")
                                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                            let looks = model.looks
                            ForEach(document.view.prefabs) { prefab in
                                HStack {
                                    Text(prefab.name.isEmpty ? prefab.id : prefab.name).font(.aeSmall).foregroundStyle(Color.ink).frame(width: 64, alignment: .leading)
                                    Picker(prefab.id, selection: Binding(get: { prefab.sprite }, set: { model.setLook(prefab.id, $0) })) {
                                        ForEach(Array(Set(looks + [prefab.sprite])).filter { !$0.isEmpty }.sorted(), id: \.self) { look in
                                            Text(verbatim: look.replacingOccurrences(of: "art/", with: "")).tag(look)
                                        }
                                    }
                                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                }
                            }
                        }
                        FeelAndSound(model: model, view: document.view, room: room)
                    }
                }
            }
            if !document.view.problems.isEmpty {
                PanelSection("Problems") {
                    ForEach(document.view.problems, id: \.self) { Text($0).font(.aeSmall).foregroundStyle(Color.coral) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .aeGlass(.panel)
    }

    /// A plane: its name, its depth to type, whether it's lit.
    private func planeRow(_ plane: GamePlane) -> some View {
        HStack(spacing: 6) {
            Text(plane.name.isEmpty ? plane.id : plane.name).font(.aeSmall).foregroundStyle(plane.gameplay ? Color.inkHi : Color.ink)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if plane.gameplay {
                Text("play").font(.aeMono).foregroundStyle(Color.ink3)
            } else if plane.parallax != nil {
                Text(verbatim: String(format: "×%.2f", plane.parallax ?? 0)).font(.aeMono).foregroundStyle(Color.ink3).help("Its own speed, whatever its depth")
            } else {
                NumberField(value: Int(plane.depth.rounded())) { model.setPlaneDepth(plane.id, Double($0)) }
                    .help(String(format: "Moves ×%.2f as fast as the play plane", GameScene.factor(plane, focal: document.view.game.view.focal)))
            }
            Toggle("Lit", isOn: Binding(get: { plane.lit }, set: { model.setPlaneLit(plane.id, $0) }))
                .toggleStyle(.checkbox).font(.aeSmall).help("Whether the room's lights fall on it")
        }
    }

    private func placeRow(_ entity: GameEntity) -> some View {
        let at = entity.at ?? Array((entity.rect ?? [0, 0]).prefix(2))
        return HStack(spacing: 8) {
            Text("At").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 34, alignment: .leading)
            NumberField(value: at[0]) { model.setPlace(entity.id, x: $0, y: at[1]) }
            NumberField(value: at[1]) { model.setPlace(entity.id, x: at[0], y: $0) }
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "transition": "Door to another room"
        case "save_point": "Bench"
        case "ability_gate": "Gate"
        case "ability_pickup": "Ability"
        case "trigger": "Trigger"
        default: kind
        }
    }
}

/// A line of collision chosen: its kind, whether it closes, its points.
private struct ShapeInspector: View {
    let model: GameWorkspaceModel
    let line: GameShape

    var body: some View {
        PanelSection(line.id) {
            // A pop-up, not segments: four of those are wider than the panel.
            HStack {
                Text("Kind").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                Picker("Kind", selection: Binding(get: { line.kind }, set: { model.setLineKind(line.id, $0) })) {
                    Text("Solid").tag("solid")
                    Text("One-way").tag("oneway")
                    Text("Hazard").tag("hazard")
                    Text("No wall").tag("nowall")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 0)
            }
            Text(kindNote).font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            Toggle("Closed", isOn: Binding(get: { line.closed }, set: { model.setLineClosed(line.id, $0) }))
                .toggleStyle(.checkbox).font(.aeSmall)
            Text(verbatim: "\(line.points.count) points").font(.aeSmall).foregroundStyle(Color.ink2)
            HStack { Spacer(); Button("Remove", role: .destructive, action: model.removeSelected).controlSize(.small) }
        }
    }

    private var kindNote: String {
        switch line.kind {
        case "oneway": "Solid only from above: jumped up through, dropped down from."
        case "hazard": "Hurts, and sends the player back to where they last stood safely."
        case "nowall": "Solid, but not a wall to cling to or jump from."
        default: "Solid from every side."
        }
    }
}

/// A light chosen: its reach, colour, brightness, waver and halo.
private struct LightInspector: View {
    let model: GameWorkspaceModel
    let light: GameLight

    var body: some View {
        PanelSection(light.id) {
            Text(verbatim: "On \(light.plane), at \(light.at.first ?? 0), \(light.at.count > 1 ? light.at[1] : 0)").font(.aeSmall).foregroundStyle(Color.ink2)
            HStack(spacing: 8) {
                Text("Reach").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                NumberField(value: light.radius) { model.setLight(light.id, "radius", max(1, $0)) }
                Text("px").font(.aeSmall).foregroundStyle(Color.ink3)
            }
            slider("Brightness", light.intensity, 0...4, "intensity")
            slider("Halo", light.glow, 0...1, "glow")
            slider("Waver", light.flicker, 0...1, "flicker")
            HStack(spacing: 8) {
                Text("Colour").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                ColorPicker("", selection: Binding(get: { color }, set: { model.setLight(light.id, "color", hex($0)) }), supportsOpacity: false)
                    .labelsHidden()
                Text(light.color).font(.aeMono).foregroundStyle(Color.ink3)
            }
            Text("It lights the lit planes, through their normal maps where they have them; ⇧P shows the finish here too.").font(.aeSmall).foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Remove", role: .destructive, action: model.removeSelected).controlSize(.small) }
        }
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ key: String) -> some View {
        StepSlider(title: title, value: value, range: range) { model.setLight(light.id, key, ($0 * 100).rounded() / 100) }
    }

    private var color: Color {
        let (r, g, b) = GameScene.rgb(light.color)
        return Color(red: r, green: g, blue: b)
    }

    private func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// A slider that makes its step once, when let go.
/// The whole game's feel and sound, under the room: how far the camera
/// leads, how hard blows shake and bodies squash, how loud sounds and music
/// are, the sound each event plays (▶ to listen), and the room's area's music.
private struct FeelAndSound: View {
    let model: GameWorkspaceModel
    let view: GameProjectView
    let room: GameRoom

    var body: some View {
        let feel = view.game.feel, audio = view.game.audio
        let files = model.audioFiles
        PanelSection("Kind") {
            Picker("Kind", selection: Binding(get: { view.game.isIsometric ? "isometric" : "metroidvania" }, set: { model.setKind($0) })) {
                Text("Side-on").tag("metroidvania")
                Text("Isometric").tag("isometric")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            Text(view.game.isIsometric
                ? "The whole game's: walking on the ground in eight ways, away up the screen at half speed, with a dash and no jumping. What stands is drawn by its feet, nearer over further."
                : "The whole game's: side-on, running, jumping and falling, with walls to cling to.")
                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
        }
        PanelSection("Feel") {
            Text("The whole game's: the camera leading the player the way they face, the screen shaking at a blow, a body stretching as it jumps and squashing as it lands.")
                .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Lead").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                NumberField(value: feel.lookahead) { model.setFeel("lookahead", Double(max(0, $0))) }
                Text("px").font(.aeSmall).foregroundStyle(Color.ink3)
            }
            StepSlider(title: "Shake", value: feel.shake, range: 0...1) { model.setFeel("shake", $0) }
            StepSlider(title: "Squash", value: feel.squash, range: 0...1) { model.setFeel("squash", $0) }
        }
        PanelSection("Sound") {
            StepSlider(title: "Sounds", value: audio.effects, range: 0...1) { model.setVolume("effects", $0) }
            StepSlider(title: "Music", value: audio.music, range: 0...1) { model.setVolume("music", $0) }
            Toggle("Silent in Play", isOn: Binding(get: { model.silent }, set: { model.silent = $0 })).toggleStyle(.checkbox).font(.aeSmall)
            ForEach(GameSound.described, id: \.name) { event in
                soundRow(event.name, help: event.what, file: audio.sounds[event.name], files: files)
            }
            // Cues animations say that have sounds, too.
            ForEach(audio.sounds.keys.filter { key in !GameSound.described.contains { $0.name == key } }.sorted(), id: \.self) { cue in
                soundRow(cue, help: "a cue an animation says", file: audio.sounds[cue], files: files)
            }
            if let area = view.world.area(of: room.id) {
                HStack(spacing: 6) {
                    Text("Music").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
                    Picker("Music", selection: Binding(get: { area.music ?? "" }, set: { model.setMusic(area.id, $0.isEmpty ? nil : $0) })) {
                        Text("None").tag("")
                        ForEach(Array(Set(files + [area.music ?? ""])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .help("What \(area.name.isEmpty ? area.id : area.name) plays, looping; it crossfades as the player goes from one area to another")
                }
            }
        }
    }

    private func soundRow(_ name: String, help: String, file: String?, files: [String]) -> some View {
        HStack(spacing: 6) {
            Text(name.capitalized).font(.aeSmall).foregroundStyle(Color.ink).frame(width: 64, alignment: .leading).help(help.prefix(1).uppercased() + help.dropFirst())
            Picker(name, selection: Binding(get: { file ?? "" }, set: { model.setSound(name, $0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(Array(Set(files + [file ?? ""])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text(verbatim: $0.replacingOccurrences(of: "audio/", with: "")).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
            Button { if let file { model.listen(file) } } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).disabled(file == nil).help("Listen")
        }
    }
}

private struct StepSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { dragging ?? value }, set: { dragging = $0 }), in: range) { editing in
                if !editing, let dragging {
                    set(dragging)
                    self.dragging = nil
                }
            }
            .controlSize(.small)
            Text(verbatim: String(format: "%.2f", dragging ?? value)).font(.aeMono).foregroundStyle(Color.ink3).frame(width: 34, alignment: .trailing)
        }
    }
}

/// A whole number typed and set on ↩ or on leaving the field.
private struct NumberField: View {
    let value: Int
    let set: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.aeMono)
            .frame(width: 80)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: value, initial: true) { text = String(value) }
    }

    private func commit() {
        if let n = Int(text.trimmingCharacters(in: .whitespaces)), n != value { set(n) } else { text = String(value) }
    }
}

// MARK: - Status, HUD and notices

private struct GameStatusBar: View {
    let model: GameWorkspaceModel
    let document: GameDocument

    var body: some View {
        HStack(spacing: 10) {
            Button { model.close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink2)
            .help("Back to the games")
            .accessibilityLabel("Back to the games")
            Text(document.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkHi)
            if let room = model.roomID {
                Divider().frame(height: 12)
                Text(room).font(.system(size: 11.5)).foregroundStyle(Color.ink)
            }
            if model.playing {
                StatePill("Playing", color: Color.live)
            } else if !document.unsaved.isEmpty {
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

/// The tools: choose and move, draw collision of a kind, place a light;
/// and undo.
private struct GameDock: View {
    @Bindable var model: GameWorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton("cursorarrow", label: "Choose and move (v)", isOn: model.tool == .select) { model.tool = .select }
            IconButton("scribble.variable", label: "Draw collision (p)", isOn: model.tool == .draw) { model.tool = .draw }
            if model.tool == .draw {
                Picker("Kind", selection: $model.drawKind) {
                    Text("Solid").tag("solid")
                    Text("One-way").tag("oneway")
                    Text("Hazard").tag("hazard")
                    Text("No wall").tag("nowall")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .padding(.horizontal, 4)
            }
            IconButton("lightbulb", label: "Place a light (l)", isOn: model.tool == .light) { model.tool = .light }
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

/// While playing: the player's health as pips, and how to stop.
private struct PlayHUD: View {
    let model: GameWorkspaceModel

    var body: some View {
        HStack(spacing: 12) {
            if model.health.most > 0 {
                HStack(spacing: 4) {
                    ForEach(0..<model.health.most, id: \.self) { i in
                        Circle().fill(i < model.health.now ? Color.coral : Color.white.opacity(0.15)).frame(width: 9, height: 9)
                    }
                }
                .accessibilityLabel("Health \(model.health.now) of \(model.health.most)")
                Divider().frame(height: 14)
            }
            Text(model.isIsometric ? "Arrows or WASD walk, X swings, C or Shift dashes" : "Arrows or WASD move, Z or Space jumps, X swings, C or Shift dashes")
                .font(.aeSmall).foregroundStyle(Color.ink)
            Button("Stop  ⎋", action: model.stop).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .aeGlass(.floating, radius: 12)
    }
}

private struct GameNotice: View {
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
