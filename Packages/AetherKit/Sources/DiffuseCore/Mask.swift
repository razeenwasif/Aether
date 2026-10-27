import CoreGraphics
import DiffuseBridge
import Foundation

/// The part of a Load Image's picture to redraw, painted as Proton's mask
/// sheet paints it: kept at the picture's own size, each pixel how painted
/// it is, 0 to 255. A stroke is dabs along the pointer's path, an eighth of
/// the brush apart, each a disc softened at its edge; the eraser takes
/// paint away the same way. Kept as a PNG, white where painted on black,
/// beside the flow; a run sends it in the picture's alpha.
public struct MaskDocument: Sendable {
    public let width: Int
    public let height: Int
    /// How painted each pixel is, row by row.
    public private(set) var coverage: [UInt8]
    private var undoStack: [[UInt8]] = []

    /// The most strokes undo takes back.
    public static let undoDepth = 30

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        coverage = Array(repeating: 0, count: width * height)
    }

    /// A mask kept as a PNG, read as a run reads it: each pixel's
    /// brightness, as far as it is opaque, is how painted it is. `nil` when
    /// it isn't a picture of this size, as Proton starts again on one that
    /// isn't.
    public init?(png: Data, width: Int, height: Int) {
        guard let pixels = try? maskFromPng(bytes: png), Int(pixels.width) == width, Int(pixels.height) == height else { return nil }
        self.width = width
        self.height = height
        coverage = [UInt8](pixels.coverage)
    }

    // MARK: Painting

    /// Begin a stroke: what undo goes back to.
    public mutating func beginStroke() {
        undoStack.append(coverage)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
    }

    /// One dab at a picture point: a disc of `size` across, solid to
    /// `1 - softness` of its radius and fading to nothing at its edge.
    public mutating func dab(at point: CGPoint, size: Double, softness: Double, erase: Bool) {
        let r = max(0.5, size / 2)
        let solid = r * (1 - min(1, max(0, softness)))
        let x0 = max(0, Int((point.x - r).rounded(.down))), x1 = min(width - 1, Int((point.x + r).rounded(.up)))
        let y0 = max(0, Int((point.y - r).rounded(.down))), y1 = min(height - 1, Int((point.y + r).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let fade = max(r - solid, 0.0001)
        let width = self.width
        coverage.withUnsafeMutableBufferPointer { pixels in
            for y in y0...y1 {
                let dy = Double(y) + 0.5 - point.y
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - point.x
                    let d = (dx * dx + dy * dy).squareRoot()
                    guard d < r else { continue }
                    let strength = d <= solid ? 1 : 1 - (d - solid) / fade
                    let old = Double(pixels[y * width + x]) / 255
                    let new = erase ? old * (1 - strength) : strength + old * (1 - strength)
                    pixels[y * width + x] = UInt8((min(1, max(0, new)) * 255).rounded())
                }
            }
        }
    }

    /// Dabs from `from` to `to`, an eighth of the brush apart, so a fast
    /// stroke is a smooth line; the dab at `from` is the last one's.
    public mutating func line(from: CGPoint, to: CGPoint, size: Double, softness: Double, erase: Bool) {
        let step = max(1, size / 8)
        let d = hypot(to.x - from.x, to.y - from.y)
        var s = step
        while s <= d {
            let t = s / d
            dab(at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), size: size, softness: softness, erase: erase)
            s += step
        }
    }

    /// Paint what wasn't, and take away what was. One undo step.
    public mutating func invert() {
        beginStroke()
        coverage = coverage.map { 255 - $0 }
    }

    /// Nothing painted. One undo step.
    public mutating func clear() {
        beginStroke()
        coverage = Array(repeating: 0, count: width * height)
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    public mutating func undo() {
        if let last = undoStack.popLast() { coverage = last }
    }

    // MARK: Reading

    /// How much of the picture is painted, as a share.
    public var share: Double {
        guard !coverage.isEmpty else { return 0 }
        return Double(coverage.reduce(0) { $0 + Int($1) }) / Double(coverage.count * 255)
    }

    /// The mask as Proton keeps it: a PNG, white where painted on black.
    public func pngData() throws -> Data {
        try maskToPng(width: UInt32(width), height: UInt32(height), coverage: Data(coverage))
    }

    /// The mask as a grey picture, white where painted, to draw over the
    /// picture it masks.
    public func coverageImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(coverage) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
