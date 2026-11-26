import CoreGraphics
import Foundation

/// A free transform as arithmetic, Proton's (`raster-transform.js`): what is
/// lifted, moved, scaled and turned while it is dragged, and the op it
/// becomes when let go.
///
/// It is kept as what a person does to it: moved by (dx, dy), scaled by
/// (sx, sy) and turned by `angle` about the middle of what was lifted. The
/// op carries it inverted — where each pixel of the result came from — in
/// 1/65536, made here once (`proton_raster::sample::Inverse`).
public struct CanvasTransform: Sendable, Equatable {
    public var cx: Double, cy: Double
    public var dx = 0.0, dy = 0.0
    public var sx = 1.0, sy = 1.0
    public var angle = 0.0

    /// Where a drag starts on it: a handle, inside to move it, or outside to
    /// turn it.
    public enum Handle: String, Sendable, Equatable {
        case move, rotate, nw, n, ne, e, se, s, sw, w
    }

    /// Nothing done yet, to what is in `rect`.
    public init(_ rect: CGRect) {
        cx = rect.midX
        cy = rect.midY
    }

    /// The transform as a matrix: a point (x, y) goes to (a·x + b·y + c,
    /// d·x + e·y + f).
    public var forward: [Double] {
        let (c, s) = (cos(angle), sin(angle))
        let (a, b, d, e) = (c * sx, -s * sy, s * sx, c * sy)
        // About the middle, then moved.
        return [a, b, cx + dx - (a * cx + b * cy), d, e, cy + dy - (d * cx + e * cy)]
    }

    /// The same as Core Animation takes one.
    public var affine: CGAffineTransform {
        let m = forward
        return CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    public static func apply(_ m: [Double], _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: m[0] * x + m[1] * y + m[2], y: m[3] * x + m[4] * y + m[5])
    }

    /// The lifted rectangle's corners where the transform puts them: top
    /// left, top right, bottom left, bottom right.
    public func corners(_ r: CGRect) -> [CGPoint] {
        let m = forward
        return [Self.apply(m, r.minX, r.minY), Self.apply(m, r.maxX, r.minY), Self.apply(m, r.minX, r.maxY), Self.apply(m, r.maxX, r.maxY)]
    }

    /// The handles, by where each is on the lifted rectangle (fractions
    /// across and down).
    private static let places: [(Handle, Double, Double)] = [
        (.nw, 0, 0), (.n, 0.5, 0), (.ne, 1, 0), (.e, 1, 0.5), (.se, 1, 1), (.s, 0.5, 1), (.sw, 0, 1), (.w, 0, 0.5),
    ]

    /// Each handle's place on the canvas.
    public func handles(_ r: CGRect) -> [(Handle, CGPoint)] {
        let m = forward
        return Self.places.map { ($0.0, Self.apply(m, r.minX + $0.1 * r.width, r.minY + $0.2 * r.height)) }
    }

    /// Which handle a canvas point is on — within `reach` canvas pixels — or
    /// whether it is inside (move) or out (turn).
    public func hit(_ r: CGRect, _ p: CGPoint, reach: Double) -> Handle {
        // A small box keeps its middle for moving: a handle reaches no more
        // than a quarter of its shorter side.
        let near = min(reach, min(abs(sx) * r.width, abs(sy) * r.height) / 4)
        for (handle, at) in handles(r) where hypot(p.x - at.x, p.y - at.y) <= near {
            return handle
        }
        let (lx, ly) = local(p)
        let inside = abs(lx) <= abs(sx) * r.width / 2 && abs(ly) <= abs(sy) * r.height / 2
        return inside ? .move : .rotate
    }

    /// A canvas point in the transform's own frame: from its moved middle,
    /// turned back.
    private func local(_ p: CGPoint) -> (Double, Double) {
        let (px, py) = (p.x - (cx + dx), p.y - (cy + dy))
        let (c, s) = (cos(-angle), sin(-angle))
        return (c * px - s * py, s * px + c * py)
    }

    /// The transform as a drag of `handle` from `from` to `to` makes it,
    /// from how it was (`self`) when the drag began. Corners scale keeping
    /// the opposite corner where it is — in proportion unless `free`; sides
    /// scale one way; a turn snaps to fifteen degrees when `snap`.
    public func dragged(_ r: CGRect, _ handle: Handle, from: CGPoint, to: CGPoint, free: Bool = false, snap: Bool = false) -> CanvasTransform {
        var t = self
        switch handle {
        case .move:
            t.dx += to.x - from.x
            t.dy += to.y - from.y
            return t
        case .rotate:
            let (mx, my) = (cx + dx, cy + dy)
            var turned = angle + atan2(to.y - my, to.x - mx) - atan2(from.y - my, from.x - mx)
            if snap { turned = (turned / (.pi / 12)).rounded() * (.pi / 12) }
            t.angle = turned
            return t
        default:
            break
        }
        // The handle's side across and down (-1, 0 or 1); the point opposite
        // it — a corner, or a side's middle — stays where it is.
        let name = handle.rawValue
        let ux: Double = name.contains("w") ? -1 : name.contains("e") ? 1 : 0
        let uy: Double = name.contains("n") ? -1 : name.contains("s") ? 1 : 0
        let (ax, ay) = (-ux * r.width / 2, -uy * r.height / 2)
        let anchor = Self.apply(forward, cx + ax, cy + ay)
        // The pointer from the anchor, in the transform's own turned frame.
        let (c, s) = (cos(angle), sin(angle))
        let (px, py) = (to.x - anchor.x, to.y - anchor.y)
        let (vx, vy) = (c * px + s * py, -s * px + c * py)
        var nsx = ux != 0 ? vx / (ux * r.width) : sx
        var nsy = uy != 0 ? vy / (uy * r.height) : sy
        if ux != 0, uy != 0, !free {
            // In proportion: as far along the corner's diagonal as the
            // pointer is.
            let (ddx, ddy) = (ux * r.width * sx, uy * r.height * sy)
            let length = ddx * ddx + ddy * ddy
            let k = (vx * ddx + vy * ddy) / (length == 0 ? 1 : length)
            (nsx, nsy) = (sx * k, sy * k)
        }
        // The middle, so the anchor stays: anchor − R·S·(the anchor from the
        // middle).
        let (hx, hy) = (nsx * ax, nsy * ay)
        let middle = CGPoint(x: anchor.x - (c * hx - s * hy), y: anchor.y - (s * hx + c * hy))
        t.sx = nsx
        t.sy = nsy
        t.dx = middle.x - cx
        t.dy = middle.y - cy
        return t
    }

    /// Whether it only moves, and by whole pixels.
    public var isWholeMove: Bool {
        angle == 0 && sx == 1 && sy == 1 && dx == dx.rounded() && dy == dy.rounded()
    }

    /// Whether it does nothing at all.
    public var isIdentity: Bool { isWholeMove && dx == 0 && dy == 0 }

    /// The op it becomes: the result's rectangle on the canvas (left, top,
    /// width, height), and where each of its pixels came from, inverted and
    /// in 1/65536. Nothing if it is all off the canvas, or squashed to
    /// nothing.
    public func op(_ r: CGRect, width: Int, height: Int) -> (bounds: [Int32], inverse: [Int64])? {
        let m = forward
        let (a, b, c, d, e, f) = (m[0], m[1], m[2], m[3], m[4], m[5])
        let det = a * e - b * d
        guard abs(det) >= 1e-9 else { return nil }
        let points = corners(r)
        let xs = points.map(\.x), ys = points.map(\.y)
        // Whole pixels, a hair in from the edges so a whole move is not a
        // pixel wider.
        let x0 = max(0, Int(floor(xs.min()! + 1e-6)))
        let y0 = max(0, Int(floor(ys.min()! + 1e-6)))
        let x1 = min(width, Int(ceil(xs.max()! - 1e-6)))
        let y1 = min(height, Int(ceil(ys.max()! - 1e-6)))
        guard x1 > x0, y1 > y0 else { return nil }
        // x = (e·(X − c) − b·(Y − f)) / det, y = (−d·(X − c) + a·(Y − f)) / det.
        let (ia, ib, id, ie) = (e / det, -b / det, -d / det, a / det)
        let ic = -(ia * c + ib * f)
        let iff = -(id * c + ie * f)
        let q = { (v: Double) -> Int64 in Int64((v * 65536).rounded()) }
        return ([Int32(x0), Int32(y0), Int32(x1 - x0), Int32(y1 - y0)], [q(ia), q(ib), q(ic), q(id), q(ie), q(iff)])
    }
}
