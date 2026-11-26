import PhotonDesign
import AppKit
import DiffuseBridge
import DiffuseCore
import Observation
import SwiftUI

/// A mask being painted over a Load Image's picture, as Proton's mask sheet
/// paints one: brush and eraser with a size and a soft edge, invert, clear,
/// and undo a stroke.
@MainActor
@Observable
public final class MaskSession {
    public enum Tool: Sendable { case brush, eraser }

    public let node: String
    /// The picture's name in the flow, for the sheet's title.
    public let name: String
    public let picture: CGImage
    public private(set) var document: MaskDocument
    /// The mask drawn over the picture, white where painted.
    public private(set) var coverage: CGImage?
    public private(set) var share: Double
    public var tool: Tool = .brush
    /// Across, in the picture's pixels.
    public var size: Double
    /// How much of the brush's radius fades, 0 to 1.
    public var softness: Double = 0.3
    /// What the mask is kept sealed with; `nil` keeps it plain.
    @ObservationIgnored let sealWith: SealKey?
    @ObservationIgnored private var last: CGPoint?

    init(node: String, name: String, picture: CGImage, document: MaskDocument, sealWith: SealKey?) {
        self.node = node
        self.name = name
        self.picture = picture
        self.document = document
        self.sealWith = sealWith
        size = Double(max(4, min(picture.width, picture.height) / 16))
        share = document.share
        coverage = document.coverageImage()
    }

    // MARK: Painting, in the picture's pixels

    func begin(at point: CGPoint) {
        document.beginStroke()
        document.dab(at: point, size: size, softness: softness, erase: tool == .eraser)
        last = point
        redraw()
    }

    func move(to point: CGPoint) {
        guard let from = last else { return begin(at: point) }
        document.line(from: from, to: point, size: size, softness: softness, erase: tool == .eraser)
        // The next line starts from the last dab, not the pointer.
        let step = max(1, size / 8)
        let d = hypot(point.x - from.x, point.y - from.y)
        if d >= step {
            let reached = (d / step).rounded(.down) * step
            last = CGPoint(x: from.x + (point.x - from.x) * reached / d, y: from.y + (point.y - from.y) * reached / d)
        }
        redraw()
    }

    func end() {
        last = nil
        share = document.share
    }

    func invert() {
        document.invert()
        changed()
    }

    func clear() {
        document.clear()
        changed()
    }

    func undo() {
        document.undo()
        changed()
    }

    func smaller() { size = max(2, (size / 1.25).rounded()) }
    func larger() { size = min(400, (size * 1.25).rounded() + 1) }

    private func changed() {
        redraw()
        share = document.share
    }

    private func redraw() { coverage = document.coverageImage() }

    /// The sheet's keys: b brush, e eraser, x swaps, i inverts, [ and ]
    /// size the brush, ⌘Z undoes a stroke. Answers whether the key was
    /// one; esc and return are the model's (cancel, done).
    func handle(_ characters: String, command: Bool) -> Bool {
        switch (characters.lowercased(), command) {
        case ("z", true): undo()
        case ("b", false): tool = .brush
        case ("e", false): tool = .eraser
        case ("x", false): tool = tool == .brush ? .eraser : .brush
        case ("i", false): invert()
        case ("[", false): smaller()
        case ("]", false): larger()
        default: return false
        }
        return true
    }
}

/// The sheet over the stage where a Load Image's mask is painted: the
/// picture fitted, the mask over it tinted, tools to the left and the
/// brush's settings to the right.
struct MaskSheet: View {
    @Bindable var model: DiffuseWorkspaceModel
    @Bindable var session: MaskSession

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture {}
            VStack(spacing: 0) {
                head
                Divider().overlay(Color.line)
                HStack(spacing: 0) {
                    tools
                    MaskStage(session: session)
                    side
                }
            }
            .aeGlass(.floating, radius: Radius.floating)
            .padding(40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paint the mask for \(session.name)")
        .accessibilityAddTraits(.isModal)
    }

    private var head: some View {
        HStack(spacing: 10) {
            Text("Mask").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.inkHi)
            Text(verbatim: "\(session.name) · \(session.picture.width) × \(session.picture.height)")
                .font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Cancel", action: model.cancelMask)
                .keyboardShortcut(.cancelAction)
            Button("Done") { model.finishMask() }
                .buttonStyle(.borderedProminent)
                .tint(Color.runFill)
                .foregroundStyle(Color.obsidian0)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var tools: some View {
        VStack(spacing: 4) {
            IconButton("paintbrush.pointed", label: "Brush (b)", isOn: session.tool == .brush) { session.tool = .brush }
            IconButton("eraser", label: "Eraser (e; x swaps)", isOn: session.tool == .eraser) { session.tool = .eraser }
            Divider().frame(width: 20).padding(.vertical, 4)
            IconButton("circle.lefthalf.filled", label: "Invert the mask (i)", action: session.invert)
            IconButton("xmark.circle", label: "Clear the mask", action: session.clear)
            IconButton("arrow.uturn.backward", label: "Undo a stroke (⌘Z)", action: session.undo)
                .disabled(!session.document.canUndo)
            Spacer()
        }
        .padding(10)
        .frame(width: 56)
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            setting("Brush size", value: "\(Int(session.size)) px") {
                Slider(value: $session.size, in: 2...400).controlSize(.small)
            }
            Text("[ and ] change it").font(.system(size: 11)).foregroundStyle(Color.ink3)
            setting("Soft edge", value: "\(Int((session.softness * 100).rounded()))%") {
                Slider(value: $session.softness, in: 0...1).controlSize(.small)
            }
            Text("\(Int((session.share * 100).rounded()))% of the picture is masked.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.inkHi)
                .padding(.top, 6)
            Text("Only what is painted is redrawn; the rest is kept as it was.")
                .font(.system(size: 11.5)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            if session.sealWith != nil {
                Label("Kept sealed", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 220)
    }

    private func setting<Control: View>(_ title: String, value: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                Spacer()
                Text(verbatim: value).font(.aeMono).foregroundStyle(Color.ink)
            }
            control()
        }
    }
}

/// The picture fitted, the mask over it in pink, and the brush's outline
/// where the pointer is; a drag paints.
private struct MaskStage: View {
    @Bindable var session: MaskSession
    @State private var hover: CGPoint?
    @State private var painting = false

    /// Proton's mask pink.
    private static let pink = Color(red: 0xF6 / 255, green: 0x94 / 255, blue: 0xFF / 255)

    var body: some View {
        GeometryReader { geo in
            let w = CGFloat(session.picture.width), h = CGFloat(session.picture.height)
            let scale = max(0.05, min(1, (geo.size.width - 24) / w, (geo.size.height - 24) / h))
            let frame = CGSize(width: w * scale, height: h * scale)
            ZStack(alignment: .topLeading) {
                Image(decorative: session.picture, scale: 1)
                    .resizable()
                    .interpolation(.high)
                if let coverage = session.coverage {
                    Self.pink
                        .mask(Image(decorative: coverage, scale: 1).resizable().interpolation(.none).luminanceToAlpha())
                        .opacity(0.5)
                }
                if let hover {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                        .background(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 3))
                        .frame(width: session.size * scale, height: session.size * scale)
                        .offset(x: hover.x - session.size * scale / 2, y: hover.y - session.size * scale / 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let at) = phase { hover = at } else { hover = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hover = value.location
                        let at = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                        if painting { session.move(to: at) } else { painting = true; session.begin(at: at) }
                    }
                    .onEnded { _ in
                        painting = false
                        session.end()
                    }
            )
            .accessibilityLabel("The picture, to paint the mask on")
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.obsidian0.opacity(0.6))
    }
}
