import AetherDesign
import ModelCore
import SwiftUI

/// The graph drawer: the chosen object's material as its node graph, the
/// design's "full graph, one toggle away". Read-only: a stack is edited as
/// layers, and a graph from Proton is kept as it is, so this shows what the
/// file holds, each node where the file puts it, fitted to the drawer.
struct MaterialGraphDrawer: View {
    let model: ModelWorkspaceModel
    let material: SceneMaterial
    let isStack: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(Color.ink2)
                Text(material.name).font(.aeBodyStrong).foregroundStyle(Color.inkHi).lineLimit(1)
                Text(note).font(.aeSmall).foregroundStyle(Color.ink2).lineLimit(1)
                Spacer()
                Button { model.toggleGraph() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .help("Hide the graph")
                .accessibilityLabel("Hide the graph")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            MaterialGraphCanvas(material: material)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .aeGlass(.floating, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(material.name)’s graph")
    }

    private var note: String {
        let n = material.nodes?.count ?? 0
        let nodes = "\(n) node\(n == 1 ? "" : "s")"
        return isStack ? "\(nodes) · written by its layers, which edit it" : "\(nodes) · a graph kept as the file has it"
    }
}

/// The boxes and wires, drawn.
struct MaterialGraphCanvas: View {
    let material: SceneMaterial

    var body: some View {
        let layout = GraphLayout(material)
        Canvas { context, size in
            guard !layout.boxes.isEmpty else { return }
            let fit = layout.fit(in: size)
            // Wires under the boxes, from an output to the row it feeds.
            for wire in layout.wires {
                let a = fit(wire.from), b = fit(wire.to)
                var path = Path()
                path.move(to: a)
                let bend = max(24, abs(b.x - a.x) * 0.45)
                path.addCurve(to: b, control1: CGPoint(x: a.x + bend, y: a.y), control2: CGPoint(x: b.x - bend, y: b.y))
                context.stroke(path, with: .color(Color.ice.opacity(0.55)), lineWidth: 1.2)
            }
            for box in layout.boxes {
                let origin = fit(box.frame.origin)
                let corner = fit(CGPoint(x: box.frame.maxX, y: box.frame.maxY))
                let rect = CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
                let shape = RoundedRectangle(cornerRadius: 5 * layout.scale(in: size)).path(in: rect)
                context.fill(shape, with: .color(Color(red: 0.11, green: 0.12, blue: 0.15)))
                let head = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: GraphLayout.head * layout.scale(in: size))
                context.fill(UnevenRoundedRectangle(topLeadingRadius: 5 * layout.scale(in: size), topTrailingRadius: 5 * layout.scale(in: size)).path(in: head), with: .color(box.tint.opacity(0.85)))
                context.stroke(shape, with: .color(Color.white.opacity(0.1)), lineWidth: 1)
                let s = layout.scale(in: size)
                guard s > 0.45 else { continue }
                let font = Font.system(size: 10 * min(s, 1.2))
                context.draw(Text(box.title).font(font.weight(.semibold)).foregroundStyle(Color.inkHi), at: CGPoint(x: head.minX + 6 * s, y: head.midY), anchor: .leading)
                for (i, row) in box.rows.enumerated() {
                    let y = rect.minY + (GraphLayout.head + GraphLayout.row * (CGFloat(i) + 0.5) + 2) * s
                    context.draw(Text(row.name).font(font).foregroundStyle(Color.ink2), at: CGPoint(x: rect.minX + 8 * s, y: y), anchor: .leading)
                    switch row.value {
                    case .number(let n)?:
                        context.draw(Text(String(format: "%.2f", n)).font(font.monospacedDigit()).foregroundStyle(Color.ink), at: CGPoint(x: rect.maxX - 6 * s, y: y), anchor: .trailing)
                    case .color(let rgb)?:
                        let swatch = CGRect(x: rect.maxX - 22 * s, y: y - 5 * s, width: 16 * s, height: 10 * s)
                        context.fill(RoundedRectangle(cornerRadius: 2).path(in: swatch), with: .color(LinearColor.color(rgb)))
                    case nil:
                        context.fill(Circle().path(in: CGRect(x: rect.minX - 3 * s, y: y - 3 * s, width: 6 * s, height: 6 * s)), with: .color(Color.ice))
                    }
                }
            }
        }
        .accessibilityLabel(layout.boxes.map(\.title).joined(separator: ", "))
    }
}

/// Where each box and wire goes, in graph units: a box a node at its `at`,
/// a row an input (a setting, or a wire in).
struct GraphLayout {
    static let width: CGFloat = 150
    static let head: CGFloat = 20
    static let row: CGFloat = 15

    struct Row { var name: String; var value: SceneMaterial.Value? }
    struct Box { var id: String; var title: String; var tint: Color; var frame: CGRect; var rows: [Row] }
    struct Wire { var from: CGPoint; var to: CGPoint }

    var boxes: [Box] = []
    var wires: [Wire] = []

    init(_ material: SceneMaterial) {
        let links = material.links ?? []
        func port(_ end: String) -> (node: String, port: String) {
            let parts = end.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts.first ?? end, parts.count > 1 ? parts[1] : "")
        }
        for node in material.nodes ?? [] {
            var rows = node.params.map { Row(name: $0.name, value: $0.value) }
            let wired = links.map { port($0.to) }.filter { $0.node == node.id }.map(\.port)
            for name in wired {
                if let i = rows.firstIndex(where: { $0.name == name }) { rows[i].value = nil } else { rows.append(Row(name: name, value: nil)) }
            }
            rows.sort { $0.name < $1.name }
            let at = CGPoint(x: node.at.first ?? 0, y: node.at.count > 1 ? node.at[1] : 0)
            let frame = CGRect(x: at.x, y: at.y, width: Self.width, height: Self.head + Self.row * CGFloat(rows.count) + 4)
            boxes.append(Box(id: node.id, title: Self.title(node), tint: Self.tint(node.kind), frame: frame, rows: rows))
        }
        for link in links {
            let (from, to) = (port(link.from), port(link.to))
            guard let a = boxes.first(where: { $0.id == from.node }), let b = boxes.first(where: { $0.id == to.node }),
                  let row = b.rows.firstIndex(where: { $0.name == to.port }) else { continue }
            wires.append(Wire(from: CGPoint(x: a.frame.maxX, y: a.frame.minY + Self.head / 2),
                              to: CGPoint(x: b.frame.minX, y: b.frame.minY + Self.head + Self.row * (CGFloat(row) + 0.5) + 2)))
        }
    }

    private var bounds: CGRect {
        boxes.map(\.frame).reduce(boxes.first?.frame ?? .zero) { $0.union($1) }
    }

    /// Points a graph unit: the whole graph fitted, never larger than life.
    func scale(in size: CGSize) -> CGFloat {
        let b = bounds.insetBy(dx: -16, dy: -16)
        return min(1.2, min(size.width / max(b.width, 1), size.height / max(b.height, 1)))
    }

    /// Graph units to the canvas, the graph centred.
    func fit(in size: CGSize) -> (CGPoint) -> CGPoint {
        let s = scale(in: size)
        let b = bounds
        let dx = (size.width - b.width * s) / 2 - b.minX * s
        let dy = (size.height - b.height * s) / 2 - b.minY * s
        return { CGPoint(x: $0.x * s + dx, y: $0.y * s + dy) }
    }

    private static func title(_ node: SceneMaterial.Node) -> String {
        switch node.kind {
        case "principled": "Surface"
        case "output": "Output"
        default: "\(node.kind.capitalized) · \(node.id)"
        }
    }

    private static func tint(_ kind: String) -> Color {
        switch kind {
        case "principled", "output": Color(red: 0.42, green: 0.36, blue: 0.7)
        case "noise", "checker": Color(red: 0.2, green: 0.5, blue: 0.48)
        case "rgb", "value": Color(red: 0.55, green: 0.42, blue: 0.22)
        default: Color(red: 0.3, green: 0.32, blue: 0.38)
        }
    }
}
