import AppKit
import CanvasCore
import Foundation
import UniformTypeIdentifiers

/// The Make panel's settings, as Proton's: a generator and a filter, each
/// with its own.
public struct CanvasMakeSettings: Equatable, Sendable {
    public enum What: String, CaseIterable, Sendable {
        case sprite, noise, cave

        public var title: String {
            switch self {
            case .sprite: "A sprite"
            case .noise: "Noise"
            case .cave: "Caves"
            }
        }
    }

    public enum FilterKind: String, CaseIterable, Sendable {
        case outline, shadow, pixelate, quantize

        public var title: String {
            switch self {
            case .outline: "Outline"
            case .shadow: "Shadow"
            case .pixelate: "Pixelate"
            case .quantize: "Fewer colours"
            }
        }
    }

    public struct Generator: Equatable, Sendable {
        public var what = What.sprite
        public var seed = UInt32.random(in: 0...UInt32.max)
        public var template = CanvasSpriteKind.ship
        public var scale = 2
        /// A sprite in a ramp of the colour drawn with, not a hue of its seed.
        public var ownColor = false
        public var noise = CanvasNoiseKind.gradient
        public var cell = 16
        public var octaves = 4
        /// Noise in the palette's colours, not a ramp of the colour drawn with.
        public var paletteColors = false
        public var steps = 5
        public var mix = CanvasNoiseMix.dither
        public var dither = 4
        public var density = 46
        public var rounds = 4
        public var caveCell = 1
        public var wrap = false
    }

    public struct Filter: Equatable, Sendable {
        public var kind = FilterKind.outline
        public var diagonal = false
        public var inside = false
        public var dx = 2
        public var dy = 2
        public var blur = 0
        /// The shadow's strength, in percent.
        public var shade = 50
        public var size = 4
        public var count = 8
        public var toPalette = false
        public var ditherColours = 0
        public var keep = true
    }

    public var generator = Generator()
    public var filter = Filter()

    public init() {}
}

public enum CanvasMakePart: Sendable {
    case generator, filter
}

/// What the Make panel shows on the canvas: the op, which part made it, and
/// its name.
public struct CanvasMaking: Equatable, Sendable {
    public let part: CanvasMakePart
    public let op: CanvasOp
    public let label: String
}

/// How the export form was last set.
public struct CanvasExportSettings: Equatable, Sendable {
    public var format = CanvasExportFormat.png
    /// Each pixel this many pixels square: 1, 2, 4 or 8.
    public var scale = 1
    /// A sheet's frames in a row, not as near a square as they make.
    public var inRow = false

    public init() {}
}

/// The Make panel (generators and filters, shown before they're kept),
/// growing by Scale2x and Scale3x, and writing a canvas out, as Proton's.
extension CanvasWorkspaceModel {
    // MARK: Make

    /// What the Make panel shows on the canvas, not kept yet: gone once the
    /// core lets go of it, as any edit, undo or stroke makes it.
    public var making: CanvasMaking? {
        document?.previewing == true ? shownMake : nil
    }

    /// The generator as set, on the layer drawn on in the frame shown.
    func generatorOp() -> CanvasOp? {
        guard let document, let layer = currentLayer else { return nil }
        let g = make.generator
        let seed = g.seed
        switch g.what {
        case .sprite:
            // In the middle of what is selected, or of the canvas.
            let r = document.selected ?? CGRect(x: 0, y: 0, width: document.width, height: document.height)
            let (w, h) = g.template.size
            let scale = Int32(max(1, g.scale))
            let at = [Int32((r.minX + (r.width - CGFloat(w * scale)) / 2).rounded()), Int32((r.minY + (r.height - CGFloat(h * scale)) / 2).rounded())]
            return .generate(layer: cel(layer), .sprite(template: g.template, seed: seed, at: at, scale: UInt32(scale), color: g.ownColor ? color : nil))
        case .noise:
            let palette = document.state.palette.map(RGBA.init)
            let colors = g.paletteColors && palette.count >= 2 ? palette : CanvasDocument.ramp(of: color, steps: UInt32(max(2, g.steps)), shift: 25, spread: 26000)
            return .generate(layer: cel(layer), .noise(g.noise, seed: seed, cell: UInt32(max(1, g.cell)), octaves: UInt32(max(1, g.octaves)), colors: colors, mix: g.mix, dither: UInt32(g.dither)))
        case .cave:
            return .generate(layer: cel(layer), .cave(seed: seed, density: UInt8(clamping: g.density), steps: UInt8(clamping: g.rounds), cell: UInt32(max(1, g.caveCell)), wrap: g.wrap, color: color))
        }
    }

    /// The filter as set, on the layer drawn on in the frame shown.
    func filterOp() -> CanvasOp? {
        guard let layer = currentLayer else { return nil }
        let f = make.filter
        let filter: CanvasFilter = switch f.kind {
        case .outline: .outline(color: color, diagonal: f.diagonal, inside: f.inside)
        case .shadow: .shadow(dx: Int32(f.dx), dy: Int32(f.dy), color: RGBA(0, 0, 0, UInt8(clamping: (f.shade * 255 + 50) / 100)), blur: UInt32(max(0, f.blur)))
        case .pixelate: .pixelate(size: UInt32(max(2, f.size)))
        case .quantize: .quantize(colors: UInt32(max(2, f.count)), palette: f.toPalette, dither: UInt32(f.ditherColours), keep: f.keep)
        }
        return .filter(layer: cel(layer), filter)
    }

    /// What a part of the panel makes, by name: for the note and Undo.
    public func madeLabel(_ part: CanvasMakePart) -> String {
        switch part {
        case .generator: ["sprite": "Sprite", "noise": "Noise", "cave": "Caves"][make.generator.what.rawValue] ?? "Make"
        case .filter: ["outline": "Outline", "shadow": "Shadow", "pixelate": "Pixelate", "quantize": "Fewer colours"][make.filter.kind.rawValue] ?? "Filter"
        }
    }

    /// A part of the panel shown on the canvas, not kept.
    public func showMade(_ part: CanvasMakePart) {
        leaveMade()
        guard let document, let op = part == .generator ? generatorOp() : filterOp() else { return }
        if let layer = currentLayer, let refusal = linkedRefusal(layer) { return notice = refusal }
        stop()
        finishTransform()
        if document.preview(op) {
            shownMake = CanvasMaking(part: part, op: op, label: madeLabel(part))
        } else {
            notice = document.refusal
        }
    }

    /// What was shown, taken away.
    public func leaveMade() {
        guard making != nil else { return }
        shownMake = nil
        document?.clearPreview()
    }

    /// A part of the panel kept, as one edit: what's shown, or as set now.
    public func keepMade(_ part: CanvasMakePart) {
        let op = making?.part == part ? making?.op : (part == .generator ? generatorOp() : filterOp())
        let label = making?.part == part ? making?.label ?? madeLabel(part) : madeLabel(part)
        leaveMade()
        if let layer = currentLayer, let refusal = linkedRefusal(layer) { return notice = refusal }
        if let op { change(op, label: label) }
    }

    /// Another seed, shown.
    public func reseed() {
        make.generator.seed = UInt32.random(in: 0...UInt32.max)
        showMade(.generator)
    }

    // MARK: Growing

    /// The whole canvas twice (Scale2x) or three times (Scale3x) the size.
    public func grow(by factor: Int) {
        change(.upscale(factor: UInt32(factor)), label: "Grow ×\(factor)")
        fit()
    }

    // MARK: Writing out

    /// The files an export makes, by name, from `name` (no extension): a
    /// PNG, a sheet's PNG and its JSON, or a Photoshop file.
    public func exportFiles(_ settings: CanvasExportSettings, name: String) throws -> [(name: String, data: Data)] {
        guard let document else { return [] }
        // What's shown and not kept isn't written out.
        leaveMade()
        switch settings.format {
        case .png:
            return [("\(name).png", try document.exportPNG(frame: frame, scale: settings.scale))]
        case .sheet:
            let sheet = try document.exportSheet(image: "\(name).png", columns: settings.inRow ? frameCount : 0, scale: settings.scale)
            return [("\(name).png", sheet.png), ("\(name).json", Data(sheet.json.utf8))]
        case .psd:
            return [("\(name).psd", document.exportPSD(frame: frame))]
        }
    }

    /// Write the canvas out where the person says, as `export` is set; a
    /// sheet's JSON goes beside its PNG.
    public func exportChosen() {
        guard let document else { return }
        askingToExport = false
        let panel = NSSavePanel()
        panel.title = "Export \(export.format.title)"
        panel.allowedContentTypes = export.format == .psd ? [UTType("com.adobe.photoshop-image") ?? .image] : [.png]
        let suffix = export.scale > 1 && export.format != .psd ? " ×\(export.scale)" : ""
        panel.nameFieldStringValue = document.name + (export.format == .sheet ? " sheet" : "") + suffix
        if export.format == .sheet { panel.message = "The sheet's JSON, as Aseprite writes it, goes beside it." }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        do {
            for file in try exportFiles(export, name: name) {
                try file.data.write(to: folder.appending(path: file.name), options: .atomic)
            }
        } catch {
            notice = "Couldn’t export \(name): \(Self.describe(error))"
        }
    }
}
