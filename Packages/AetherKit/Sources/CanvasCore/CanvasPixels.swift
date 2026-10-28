import CoreGraphics
import DiffuseBridge
import Foundation

/// The canvas laid together, premultiplied RGBA, kept here as the core lays
/// parts of it, and cut into the 64 × 64 tiles the core works in, each a
/// picture for a view to draw. Only tiles that changed are made again.
public final class CanvasPixels: @unchecked Sendable {
    public static let tile = 64
    public private(set) var width: Int
    public private(set) var height: Int
    private var buffer: [UInt8]
    /// Tiles changed since a view last asked, by index.
    private var changed = Set<Int>()
    private let lock = NSLock()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        buffer = Array(repeating: 0, count: width * height * 4)
    }

    public var columns: Int { (width + Self.tile - 1) / Self.tile }
    public var rows: Int { (height + Self.tile - 1) / Self.tile }

    func resize(width: Int, height: Int) {
        lock.withLock {
            self.width = width
            self.height = height
            buffer = Array(repeating: 0, count: width * height * 4)
            changed = Set(0..<(columns * rows))
        }
    }

    /// Parts the core laid, written in.
    func take(_ parts: [Laid]) {
        lock.withLock {
            for part in parts {
                let (x, y, w, h) = (Int(part.x), Int(part.y), Int(part.width), Int(part.height))
                guard x + w <= width, y + h <= height, part.pixels.count >= w * h * 4 else { continue }
                part.pixels.withUnsafeBytes { source in
                    buffer.withUnsafeMutableBytes { target in
                        for row in 0..<h {
                            let from = row * w * 4
                            let to = ((y + row) * width + x) * 4
                            target.baseAddress!.advanced(by: to).copyMemory(from: source.baseAddress!.advanced(by: from), byteCount: w * 4)
                        }
                    }
                }
                for ty in (y / Self.tile)...((y + h - 1) / Self.tile) {
                    for tx in (x / Self.tile)...((x + w - 1) / Self.tile) { changed.insert(ty * columns + tx) }
                }
            }
        }
    }

    /// The tiles changed since last asked; asking forgets them.
    public func takeChanged() -> Set<Int> {
        lock.withLock {
            defer { changed = [] }
            return changed
        }
    }

    /// Where tile `index` sits, in canvas pixels.
    public func frame(of index: Int) -> CGRect {
        let tx = index % max(columns, 1), ty = index / max(columns, 1)
        let x = tx * Self.tile, y = ty * Self.tile
        return CGRect(x: x, y: y, width: min(Self.tile, width - x), height: min(Self.tile, height - y))
    }

    /// Tile `index` as a picture.
    public func image(of index: Int) -> CGImage? {
        let r = frame(of: index)
        let (x, y, w, h) = (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        lock.withLock {
            buffer.withUnsafeBytes { source in
                bytes.withUnsafeMutableBytes { target in
                    for row in 0..<h {
                        target.baseAddress!.advanced(by: row * w * 4)
                            .copyMemory(from: source.baseAddress!.advanced(by: ((y + row) * width + x) * 4), byteCount: w * 4)
                    }
                }
            }
        }
        return Self.image(Data(bytes), width: w, height: h)
    }

    /// Premultiplied RGBA, row by row, as a picture.
    public static func image(_ bytes: Data, width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A pixel, premultiplied, for tests.
    public func pixel(x: Int, y: Int) -> [UInt8] {
        lock.withLock {
            let i = (y * width + x) * 4
            return Array(buffer[i..<i + 4])
        }
    }
}
