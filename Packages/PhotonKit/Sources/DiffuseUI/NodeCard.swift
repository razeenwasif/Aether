import PhotonDesign
import AppKit
import DiffuseBridge
import DiffuseCore
import SwiftUI

/// One node: a header, its sockets (inputs left, outputs right), its fields
/// as read-only rows (edited in the inspector), and what a run shows on it.
struct NodeCard: View {
    let node: FlowNode
    let type: NodeType?
    let editor: FlowEditor
    let model: DiffuseWorkspaceModel
    let wire: PendingWire?
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    let onPortDrag: (FlowPort, Bool, CGPoint) -> Void
    let onPortDragEnd: (CGPoint) -> Void

    private var geometry: NodeGeometry { NodeGeometry(node: node, type: type) }
    private var selected: Bool { editor.selection.contains(node.id) }
    private var problems: [Problem] { editor.problems(at: node.id) }
    private var run: RunItem? { model.queue.runs.first }
    private var state: NodeRunState? { run?.phase.isLive == true ? run?.nodeStates[node.id] : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            sockets
            fields
            Spacer(minLength: NodeMetrics.bottom)
                .frame(height: NodeMetrics.bottom)
            media
        }
        .frame(width: NodeMetrics.width, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Radius.node, style: .continuous)
                .fill(selected ? Color.raise2 : Color.raise1))
        .overlay(border)
        .overlay(alignment: .topLeading) { ports }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .opacity(node.isBypassed ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.node))
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                editor.selection.formSymmetricDifference([node.id])
            } else {
                editor.selection = [node.id]
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("flow"))
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnd() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(type?.title ?? node.type) node \(node.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.selection = [node.id] }
        .accessibilityAction(named: "Duplicate") {
            editor.selection = [node.id]
            model.duplicateSelection()
        }
        .accessibilityAction(named: node.isBypassed ? "Restore" : "Bypass") {
            editor.selection = [node.id]
            model.toggleBypass()
        }
        .accessibilityAction(named: "Run to here") { model.runTo(node.id) }
        .contextMenu {
            Button("Run to Here") { model.runTo(node.id) }
                .disabled(node.isBypassed)
            Divider()
            Button("Duplicate") {
                editor.selection = [node.id]
                model.duplicateSelection()
            }
            Button(node.isBypassed ? "Restore" : "Bypass") {
                editor.selection = [node.id]
                model.toggleBypass()
            }
            Divider()
            Button("Delete", role: .destructive) {
                editor.selection = [node.id]
                model.deleteSelection()
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: GroupStyle.symbol(type?.group ?? ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.ice : Color.ink)
            Text(type?.title ?? node.type)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkHi)
                .lineLimit(1)
            Spacer(minLength: 4)
            if node.isBypassed {
                Text("Bypassed").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink2)
            }
            stateBadge
            if !problems.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.amber)
                    .help(problems.map(\.message).joined(separator: "\n"))
            }
            Text(node.id).font(.aeMono).foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, 10)
        .frame(height: NodeMetrics.header)
        .overlay(alignment: .bottom) { progressBar }
    }

    @ViewBuilder private var stateBadge: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).tint(.ice)
        case .cached:
            Text("cached").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.live)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.live)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var progressBar: some View {
        if let steps = run?.steps[node.id], run?.phase.isLive == true {
            GeometryReader { geo in
                Rectangle().fill(Color.ice).frame(width: geo.size.width * steps.fraction, height: 2)
            }
            .frame(height: 2)
        }
    }

    private var sockets: some View {
        VStack(spacing: 0) {
            ForEach(0..<geometry.socketRows, id: \.self) { row in
                HStack(spacing: 6) {
                    if let input = type?.sockets[safe: row] {
                        Text(input.name + (input.isOptional ? "?" : ""))
                            .foregroundStyle(problemAt(input.name) ? Color.amber : Color.ink2)
                    }
                    Spacer(minLength: 6)
                    if let output = type?.outputs[safe: row] {
                        Text(output.name).foregroundStyle(Color.ink2)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .frame(height: NodeMetrics.socketRow)
            }
        }
        .padding(.top, NodeMetrics.rowsTop)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            ForEach(type?.fields ?? [], id: \.name) { field in
                FieldRow(field: field, value: node.values[field.name] ?? field.default, seed: node.seed, flagged: problemAt(field.name))
                    .frame(height: NodeGeometry.fieldHeight(field))
            }
        }
    }

    /// A sampler's live preview, or the newest picture an output node made.
    @ViewBuilder private var media: some View {
        if let image = mediaImage, image.size.width > 0 {
            // Sized from the picture, so the card ends where the picture does.
            let width = NodeMetrics.width - 20
            let height = min(260, width * image.size.height / image.size.width)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .padding(.bottom, 10)
                .accessibilityLabel("Output picture")
        } else if let picture = pictureOnDisk {
            CardPicture(url: picture, key: model.sealKey)
                .id(model.pictureRevision)
        }
    }

    /// A Load Image's picture, where it is on disk, when it is there.
    private var pictureOnDisk: URL? {
        guard let field = editor.pictureField(of: node), let name = node.values[field]?.stringValue, !name.isEmpty else { return nil }
        let url = FlowInputs.onDisk(name, flow: editor.url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var mediaImage: NSImage? {
        if let run, run.phase.isLive, let preview = run.preview, preview.node == node.id {
            return NSImage(data: preview.jpeg)
        }
        // An output's newest picture, or a run to here's on the node run to.
        if let output = model.latestOutput(at: node.id) {
            return NSImage(data: output.data)
        }
        return nil
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.node, style: .continuous)
        return ZStack {
            if selected {
                shape.strokeBorder(Color.ice, lineWidth: 1.5)
                shape.stroke(Color.ice.opacity(0.18), lineWidth: 6)
            } else if state == .running {
                shape.strokeBorder(Color.ice.opacity(0.7), lineWidth: 1.2)
            } else if node.isBypassed {
                shape.strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    // MARK: Ports

    private var ports: some View {
        ZStack(alignment: .topLeading) {
            ForEach(type?.sockets ?? [], id: \.name) { input in
                let port = FlowPort(node: node.id, name: input.name)
                PortDot(socket: input.type, linked: editor.flow.link(into: port.text) != nil, glowing: accepts(input: input))
                    .position(geometry.inputPoint(input.name))
                    .gesture(portDrag(port, isInput: true))
                    .help("\(input.name) · \(input.type ?? "")")
            }
            ForEach(type?.outputs ?? [], id: \.name) { output in
                let port = FlowPort(node: node.id, name: output.name)
                PortDot(socket: output.type, linked: editor.flow.links.contains { $0.from == port.text }, glowing: accepts(output: output))
                    .position(geometry.outputPoint(output.name))
                    .gesture(portDrag(port, isInput: false))
                    .help("\(output.name) · \(output.type)")
            }
        }
        .frame(width: NodeMetrics.width, height: geometry.bodyHeight, alignment: .topLeading)
    }

    private func portDrag(_ port: FlowPort, isInput: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("flow"))
            .onChanged { onPortDrag(port, isInput, $0.location) }
            .onEnded { onPortDragEnd($0.location) }
    }

    /// While a wire is drawn, the ports it could land on glow.
    private func accepts(input: NodeInput) -> Bool {
        guard let wire, wire.output != nil, wire.output?.node != node.id else { return false }
        return wire.socket == input.type
    }

    private func accepts(output: NodeOutput) -> Bool {
        guard let wire, wire.input != nil, wire.input?.node != node.id else { return false }
        return wire.socket == output.type
    }

    private func problemAt(_ input: String) -> Bool {
        problems.contains { $0.input == input }
    }
}

/// A port: a ring in its socket's colour, filled when linked.
private struct PortDot: View {
    let socket: String?
    let linked: Bool
    let glowing: Bool

    var body: some View {
        let color = SocketStyle.color(socket)
        ZStack {
            if glowing { Circle().fill(color.opacity(0.25)).frame(width: 20, height: 20) }
            Circle().fill(linked ? color : Color.raise1).frame(width: 10, height: 10)
            Circle().strokeBorder(color, lineWidth: 2).frame(width: 10, height: 10)
        }
        .frame(width: NodeMetrics.hitRadius * 2, height: NodeMetrics.hitRadius * 2)
        .contentShape(Circle())
    }
}

/// A field as the node shows it: its name and value, one line (two for
/// text written over several lines).
private struct FieldRow: View {
    let field: NodeInput
    let value: JSONValue?
    let seed: SeedMode?
    let flagged: Bool

    var body: some View {
        if field.multiline == true {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.name).font(.system(size: 10.5)).foregroundStyle(flagged ? Color.amber : Color.ink2)
                Text(value?.stringValue ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                Text(field.name).foregroundStyle(flagged ? Color.amber : Color.ink2)
                Spacer(minLength: 8)
                if field.fieldKind == .seed, let seed, seed != .fixed {
                    Image(systemName: seed == .random ? "dice" : "plus.forwardslash.minus")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.ink2)
                }
                Text(value?.display ?? "—")
                    .font(isNumber ? .aeMono : .system(size: 11))
                    .foregroundStyle(Color.inkHi)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
        }
    }

    private var isNumber: Bool {
        switch field.fieldKind {
        case .int, .float, .seed: true
        default: false
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A Load Image's picture on its card, sized from the picture like an
/// output's, once its thumbnail is made.
private struct CardPicture: View {
    let url: URL
    let key: SealKey?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image, image.width > 0 {
                let width = NodeMetrics.width - 20
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: min(260, width * CGFloat(image.height) / CGFloat(image.width)))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                    .padding(.bottom, 10)
                    .accessibilityLabel("Input picture")
            } else {
                // Something to appear, so the thumbnail is asked for.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: HeadRequest(url: url, unlocked: key != nil)) {
            image = await Thumbnails.shared.image(url, side: 480, key: key)
        }
    }
}
