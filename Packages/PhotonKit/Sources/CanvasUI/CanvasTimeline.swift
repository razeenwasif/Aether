import PhotonDesign
import CanvasCore
import SwiftUI

/// The frames under the picture, as Proton's timeline: the frame shown and
/// how long it shows, playing, onion skin, frames added, copied and taken
/// out — and every frame small, with its tags over it. Drag a frame to move
/// it; click a tag to play it.
struct CanvasTimeline: View {
    @Bindable var model: CanvasWorkspaceModel
    let document: CanvasDocument
    @State private var ms = ""
    @FocusState private var typingMs: Bool

    /// A frame's cell, and the gap between cells.
    static let cell: CGFloat = 52
    static let gap: CGFloat = 4

    /// Tags' colours by their place: Proton's.
    static let tagColours: [Color] = [0xb0303f, 0x2f6fb0, 0x3e9e5c, 0xe8743b, 0x6b3fa0, 0x1f5f5b, 0xe07ab8, 0xf4c95d].map { (hex: UInt32) in
        Color(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }

    /// How tall it is, for fitting the canvas above it.
    static func height(frames: Int) -> CGFloat { 120 }

    var body: some View {
        let n = model.frameCount
        VStack(alignment: .leading, spacing: 6) {
            bar(n)
            strip(n)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 760)
        .aeGlass(.floating, radius: 12)
        // Thumbnails drawn again a moment after frames change, not at every step.
        .task(id: document.framesDrawn) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            model.refreshThumbs()
        }
        .onAppear { ms = currentMs }
        .onChange(of: currentMs) { if !typingMs { ms = currentMs } }
        .onChange(of: typingMs) { if !typingMs { ms = currentMs } }
    }

    private var currentMs: String { String(document.state.frames[safe: model.frame] ?? 100) }

    private func bar(_ n: Int) -> some View {
        HStack(spacing: 2) {
            IconButton("backward.end.fill", label: "The frame before (,)") { model.stepFrame(by: -1) }
            IconButton(model.playing ? "pause.fill" : "play.fill", label: model.playing ? "Stop (↩)" : "Play the frames (↩)") { model.togglePlaying() }
                .disabled(n < 2)
            IconButton("forward.end.fill", label: "The frame after (.)") { model.stepFrame(by: 1) }
            Text(verbatim: "\(model.frame + 1) / \(n)").font(.aeMono).foregroundStyle(Color.ink).frame(minWidth: 52)
            TextField("ms", text: $ms)
                .textFieldStyle(.plain)
                .font(.aeMono)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($typingMs)
                .onSubmit {
                    if let value = Int(ms.trimmingCharacters(in: .whitespaces)) { model.setDuration(value) }
                    ms = currentMs
                }
                .help("How long this frame shows, in milliseconds")
                .accessibilityLabel("Milliseconds this frame shows")
            Text("ms").font(.aeSmall).foregroundStyle(Color.ink2)
            Spacer(minLength: 8)
            if !model.tags.isEmpty {
                Picker("What plays", selection: $model.playTag) {
                    Text("Every frame").tag("")
                    ForEach(model.tags, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 140)
            }
            IconButton("circle.lefthalf.filled", label: "Onion skin: the frames either side, faintly (⇧O)", isOn: model.onionOn) { model.onionOn.toggle() }
            Divider().frame(height: 18).padding(.horizontal, 4)
            IconButton("plus", label: "A new, clear frame after this one", action: model.addFrame)
            IconButton("plus.square.on.square", label: "A copy of this frame, after it (⇧N)", action: model.copyFrame)
            IconButton("xmark", label: "Take this frame out", action: model.removeFrame)
                .disabled(n < 2)
        }
    }

    private func strip(_ n: Int) -> some View {
        let step = Self.cell + Self.gap
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !model.tags.isEmpty {
                        ZStack(alignment: .topLeading) {
                            Color.clear.frame(width: CGFloat(n) * step, height: 16)
                            ForEach(Array(model.tags.enumerated()), id: \.offset) { i, tag in
                                tagBar(tag, colour: Self.tagColours[i % Self.tagColours.count])
                                    .frame(width: CGFloat(Int(tag.to) - Int(tag.from) + 1) * step - Self.gap, height: 16)
                                    .offset(x: CGFloat(tag.from) * step)
                            }
                        }
                    }
                    HStack(spacing: Self.gap) {
                        ForEach(0..<n, id: \.self) { i in
                            frameCell(i).id(i)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: model.frame) { proxy.scrollTo(model.frame) }
        }
    }

    private func tagBar(_ tag: CanvasTag, colour: Color) -> some View {
        let on = model.playTag == tag.name
        return Button {
            model.playTag = on ? "" : tag.name
        } label: {
            Text(tag.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(colour.opacity(on ? 1 : 0.6)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(on ? 0.7 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Play “\(tag.name)”, frames \(tag.from + 1)–\(tag.to + 1)")
    }

    private func frameCell(_ i: Int) -> some View {
        let on = i == model.frame
        let ms = document.state.frames[safe: i] ?? 100
        return Button {
            model.showFrame(i)
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Checkerboard()
                    if let image = model.thumbs[i] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(document.state.preset == .pixel ? .none : .medium)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(verbatim: "\(i + 1)").font(.system(size: 10, weight: on ? .bold : .regular)).foregroundStyle(on ? Color.inkHi : Color.ink2)
            }
            .frame(width: Self.cell, height: 58)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.white.opacity(0.4) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Frame \(i + 1): \(ms) ms — drag it to move it")
        .accessibilityLabel("Frame \(i + 1)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .draggable(String(i))
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap({ Int($0) }) else { return false }
            model.moveFrame(from, to: i)
            return true
        }
    }
}
