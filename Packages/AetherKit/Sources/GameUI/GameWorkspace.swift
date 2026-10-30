import AetherDesign
import GameCore
import SwiftUI

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
                GameStage(model: model, revision: document.revision, roomID: model.roomID, selected: model.selected, playing: model.playing, fitRequest: model.fitRequest)
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
                    GameNotice(text: notice) { model.notice = nil }
                }
                if model.playing {
                    PlayHUD(model: model).padding(.bottom, 16)
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
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
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
                Text("A Metroidvania from Proton's template: two rooms, a player, a crawler, a bench and a gate, their art drawn in code.")
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
                            row(entity.id, detail: document.view.prefab(entity.prefab)?.name ?? entity.prefab, dirty: false, chosen: entity.id == model.selected) {
                                model.selected = entity.id
                            }
                        }
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
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.white.opacity(0.08) : .clear))
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
            if let id = model.selected, let entity = model.room?.entity(id) {
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
                    Text("Click a thing to choose it, drag it to move it. Drag nothing or use two fingers to move over the room; pinch or ⌘-scroll to zoom; f shows it all.")
                        .font(.aeSmall).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("Planes") {
                    ForEach(room.planes) { plane in
                        HStack {
                            Text(plane.name.isEmpty ? plane.id : plane.name).font(.aeBody).foregroundStyle(plane.gameplay ? Color.inkHi : Color.ink)
                            Spacer()
                            Text(verbatim: plane.gameplay ? "play" : String(format: "×%.2f", GameScene.factor(plane, focal: document.view.game.view.focal)))
                                .font(.aeMono).foregroundStyle(Color.ink3)
                        }
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
            Text("Arrows or WASD move, Z or Space jumps, X swings, C or Shift dashes").font(.aeSmall).foregroundStyle(Color.ink)
            Button("Stop  ⎋", action: model.stop).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .aeGlass(.floating, radius: 12)
    }
}

private struct GameNotice: View {
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
        .frame(maxWidth: 560)
        .aeGlass(.floating, radius: 10)
        .padding(.bottom, 4)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}
