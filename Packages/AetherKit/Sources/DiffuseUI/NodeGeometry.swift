import AetherDesign
import DiffuseCore
import SwiftUI

/// The fixed measures a node card is drawn to, so wires can find its ports
/// without measuring views.
enum NodeMetrics {
    static let width: CGFloat = 236
    static let header: CGFloat = 32
    static let rowsTop: CGFloat = 6
    static let socketRow: CGFloat = 24
    static let fieldRow: CGFloat = 22
    static let multilineRow: CGFloat = 52
    static let bottom: CGFloat = 8
    static let portRadius: CGFloat = 5
    static let hitRadius: CGFloat = 16
}

/// Where everything on one node is, relative to its top-left corner.
struct NodeGeometry {
    let node: FlowNode
    let type: NodeType?

    var socketRows: Int { max(type?.sockets.count ?? 0, type?.outputs.count ?? 0) }

    func inputPoint(_ name: String) -> CGPoint {
        guard let index = type?.sockets.firstIndex(where: { $0.name == name }) else {
            return CGPoint(x: 0, y: NodeMetrics.header / 2)
        }
        return CGPoint(x: 0, y: rowCentre(index))
    }

    func outputPoint(_ name: String) -> CGPoint {
        guard let index = type?.outputs.firstIndex(where: { $0.name == name }) else {
            return CGPoint(x: NodeMetrics.width, y: NodeMetrics.header / 2)
        }
        return CGPoint(x: NodeMetrics.width, y: rowCentre(index))
    }

    func rowCentre(_ index: Int) -> CGFloat {
        NodeMetrics.header + NodeMetrics.rowsTop + CGFloat(index) * NodeMetrics.socketRow + NodeMetrics.socketRow / 2
    }

    static func fieldHeight(_ field: NodeInput) -> CGFloat {
        field.multiline == true ? NodeMetrics.multilineRow : NodeMetrics.fieldRow
    }

    /// The card's height without any picture under it.
    var bodyHeight: CGFloat {
        let fields = (type?.fields ?? []).reduce(0) { $0 + Self.fieldHeight($1) }
        return NodeMetrics.header + NodeMetrics.rowsTop + CGFloat(socketRows) * NodeMetrics.socketRow + fields + NodeMetrics.bottom
    }
}

/// What each socket type is drawn in. Colour is the second cue: every port
/// is also labelled, and the colours differ in lightness as well as hue.
enum SocketStyle {
    static func color(_ type: String?) -> Color {
        switch type {
        case "MODEL": Color(hex: 0xA3A8B2)
        case "CLIP": Color(hex: 0xE2C08D)
        case "VAE": Color(hex: 0xFF8A7A)
        case "CONDITIONING": .lavender
        case "LATENT": .live
        case "IMAGE": .ice
        case "MASK": Color(hex: 0xD5D8DE)
        case "UPSCALER": Color(hex: 0x8CCB8A)
        default: .ink2
        }
    }
}

/// The glyph for a catalogue group.
enum GroupStyle {
    static func symbol(_ group: String) -> String {
        switch group {
        case "Load": "shippingbox"
        case "Prompt": "text.alignleft"
        case "Latent": "square.stack.3d.down.right"
        case "Sample": "sparkles"
        case "Image": "photo"
        case "Output": "square.and.arrow.down"
        default: "circle.grid.2x2"
        }
    }
}
