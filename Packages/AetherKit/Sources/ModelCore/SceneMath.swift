import Foundation
import simd

/// The viewport's maths, as Proton's `viewport.js` has it: transforms
/// composed scale, then rotation (XYZ in degrees, R = Rz·Ry·Rx), then
/// translation, and applied parents first; an orbit camera; and picking by
/// each object's box on screen.
public enum SceneMath {
    /// The field of view, top to bottom.
    public static let fov: Float = 50 * .pi / 180

    /// An object's own transform.
    public static func compose(position p: [Double], rotation r: [Double], scale s: [Double]) -> simd_float4x4 {
        func at(_ v: [Double], _ i: Int, _ fallback: Double) -> Float { Float(v.count > i ? v[i] : fallback) }
        let (rx, ry, rz) = (at(r, 0, 0) * .pi / 180, at(r, 1, 0) * .pi / 180, at(r, 2, 0) * .pi / 180)
        let (cx, sx, cy, sy, cz, sz) = (cos(rx), sin(rx), cos(ry), sin(ry), cos(rz), sin(rz))
        let (kx, ky, kz) = (at(s, 0, 1), at(s, 1, 1), at(s, 2, 1))
        return simd_float4x4(columns: (
            SIMD4(cy * cz * kx, cy * sz * kx, -sy * kx, 0),
            SIMD4((sx * sy * cz - cx * sz) * ky, (sx * sy * sz + cx * cz) * ky, sx * cy * ky, 0),
            SIMD4((cx * sy * cz + sx * sz) * kz, (cx * sy * sz - sx * cz) * kz, cx * cy * kz, 0),
            SIMD4(at(p, 0, 0), at(p, 1, 0), at(p, 2, 0), 1)
        ))
    }

    /// Every object's place in the world, by id: its parents' transforms then
    /// its own. The list comes parents first, so one pass does it.
    public static func worlds(_ nodes: [SceneNode]) -> [String: simd_float4x4] {
        var out: [String: simd_float4x4] = [:]
        for node in nodes {
            let local = compose(position: node.position, rotation: node.rotation, scale: node.scale)
            out[node.id] = out[node.parent].map { $0 * local } ?? local
        }
        return out
    }

    /// The view from `eye` looking at `target`, y up.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(SIMD3(0, 1, 0), z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    /// A perspective projection for Metal, whose depth runs 0 to 1; `fov`
    /// top to bottom, in radians.
    public static func perspective(aspect: Float, near: Float, far: Float, fov: Float = SceneMath.fov) -> simd_float4x4 {
        let f = 1 / tan(fov / 2)
        return simd_float4x4(columns: (
            SIMD4(f / max(aspect, 1e-4), 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)
        ))
    }

    /// An orthographic projection for Metal, depth 0 to 1: a sun's shadow.
    public static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0),
            SIMD4((left + right) / (left - right), (top + bottom) / (bottom - top), near / (near - far), 1)
        ))
    }

    /// The view through something placed in the world, looking down its own
    /// −Z with its +Y up, as a camera's stand-in draws it: its world with the
    /// scale taken out, inverted.
    public static func view(through world: simd_float4x4) -> simd_float4x4 {
        func axis(_ c: SIMD4<Float>) -> SIMD4<Float> {
            let v = SIMD3(c.x, c.y, c.z)
            let l = simd_length(v)
            return l > 1e-8 ? SIMD4(v / l, 0) : SIMD4(0, 0, 0, 0)
        }
        let unscaled = simd_float4x4(columns: (axis(world.columns.0), axis(world.columns.1), axis(world.columns.2), world.columns.3))
        return unscaled.inverse
    }

    /// A rotation's angles, in degrees, as a transform's `rotation` holds
    /// them (R = Rz·Ry·Rx): the inverse of `compose`'s turn.
    public static func degrees(of r: simd_float3x3) -> [Double] {
        let (c0, c1, c2) = (r.columns.0, r.columns.1, r.columns.2)
        let sy = max(-1, min(1, -c0.z))
        let y = asin(sy)
        let x: Float, z: Float
        if abs(cos(y)) > 1e-5 {
            x = atan2(c1.z, c2.z)
            z = atan2(c0.y, c0.x)
        } else {
            // Straight up or down: the x and z turns are the same turn.
            x = atan2(-c2.y, c1.y)
            z = 0
        }
        return [x, y, z].map { (Double($0) * 180 / .pi * 1e4).rounded() / 1e4 }
    }

    /// The eight corners of an object's box, in the world: its mesh's, or a
    /// metre's for anything drawn as a stand-in.
    public static func corners(bounds: [Float]?, world: simd_float4x4) -> [SIMD3<Float>] {
        let b = bounds.flatMap { $0.count == 6 && $0[3] >= $0[0] ? $0 : nil } ?? [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5]
        var out: [SIMD3<Float>] = []
        for x in [b[0], b[3]] {
            for y in [b[1], b[4]] {
                for z in [b[2], b[5]] {
                    let p = world * SIMD4(x, y, z, 1)
                    out.append(SIMD3(p.x, p.y, p.z))
                }
            }
        }
        return out
    }

    /// Where a point in the world lands on a viewport `size` points large
    /// (y down from the top), or `nil` behind the camera.
    public static func project(_ p: SIMD3<Float>, view: simd_float4x4, size: CGSize) -> CGPoint? {
        let focal = Float(size.height) * 0.5 / tan(fov / 2)
        let e = view * SIMD4(p, 1)
        guard e.z < -0.01 else { return nil }
        return CGPoint(x: CGFloat(Float(size.width) / 2 + focal * e.x / -e.z), y: CGFloat(Float(size.height) / 2 - focal * e.y / -e.z))
    }

    /// The object under a point on the viewport (points, y down from the
    /// top), by each object's box on screen, the nearest winning; `nil` for
    /// none. Proton's `pick`: on the processor, from numbers to hand.
    public static func pick(_ point: CGPoint, size: CGSize, view: simd_float4x4, boxes: [(id: String, corners: [SIMD3<Float>])]) -> String? {
        let focal = Float(size.height) * 0.5 / tan(fov / 2)
        var best: (id: String, near: Float)?
        for box in boxes {
            var lo = SIMD2<Float>(.infinity, .infinity)
            var hi = SIMD2<Float>(-.infinity, -.infinity)
            var near = Float.infinity
            var seen = 0
            for corner in box.corners {
                let p = view * SIMD4(corner, 1)
                guard p.z < -0.01 else { continue }
                seen += 1
                let s = SIMD2(Float(size.width) / 2 + focal * p.x / -p.z, Float(size.height) / 2 - focal * p.y / -p.z)
                lo = simd_min(lo, s)
                hi = simd_max(hi, s)
                near = min(near, -p.z)
            }
            // Grown a little, so a thing seen edge-on can still be hit.
            let pad: Float = 6
            let (x, y) = (Float(point.x), Float(point.y))
            guard seen > 0, x >= lo.x - pad, x <= hi.x + pad, y >= lo.y - pad, y <= hi.y + pad else { continue }
            if near < best?.near ?? .infinity { best = (box.id, near) }
        }
        return best?.id
    }
}

/// The camera the viewer drives: around a target, at a distance.
public struct OrbitCamera: Equatable, Sendable {
    public var yaw: Float = 0.7
    public var pitch: Float = 0.5
    public var distance: Float = 12
    public var target = SIMD3<Float>(0, 0, 0)

    public init() {}

    public var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    public var view: simd_float4x4 { SceneMath.lookAt(eye: eye, target: target) }

    /// Turned by a drag of `dx`, `dy` points; held short of the poles, where
    /// the picture would flip.
    public mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(1.5, max(-1.5, pitch + dy * 0.008))
    }

    /// Slid along its own axes, scaled by distance, so the ground moves with
    /// the pointer at any zoom.
    public mutating func pan(dx: Float, dy: Float) {
        let v = view
        let right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let up = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        let k = distance * 0.0015
        target += -dx * k * right + dy * k * up
    }

    /// Nearer or farther by a factor, so a step feels the same at any range.
    public mutating func zoom(by factor: Float) {
        distance = min(400, max(0.5, distance * factor))
    }

    /// Framing `points`: aimed at their middle, far enough back to see them.
    public mutating func frame(_ points: [SIMD3<Float>]) {
        guard let first = points.first else { return }
        var lo = first, hi = first
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        target = (lo + hi) / 2
        let radius = max(0.5, simd_length(hi - lo) / 2)
        distance = min(400, max(0.5, radius / sin(SceneMath.fov / 2) * 1.15))
    }
}
