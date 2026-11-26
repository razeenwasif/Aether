import Foundation

/// The order frames play in, Proton's (`raster-frames.js`): on to the last
/// and round again, back from the last, or to the end and back — over every
/// frame or a tag's run of them.
public struct CanvasRun: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var direction: CanvasDirection

    /// A tag's run, or every frame, on.
    public init(frames: Int, tag: CanvasTag?) {
        if let tag, tag.from <= tag.to, Int(tag.to) < frames {
            (from, to, direction) = (Int(tag.from), Int(tag.to), tag.direction)
        } else {
            (from, to, direction) = (0, max(0, frames - 1), .forward)
        }
    }

    private var backward: Bool { direction == .reverse || direction == .pingPongReverse }

    /// Where playing begins — from `at` when it is in the run — and which
    /// way it goes.
    public func start(at: Int? = nil) -> (frame: Int, forward: Bool) {
        if let at, at >= from, at <= to { return (at, !backward) }
        return backward ? (to, false) : (from, true)
    }

    /// The frame after `at`, and which way it goes after that.
    public func step(at: Int, forward: Bool) -> (frame: Int, forward: Bool) {
        guard at >= from, at <= to else { return start() }
        guard from != to else { return (from, forward) }
        switch direction {
        case .forward:
            return (at == to ? from : at + 1, true)
        case .reverse:
            return (at == from ? to : at - 1, false)
        case .pingPong, .pingPongReverse:
            // To the end and back, the ends shown once each time round.
            if forward { return at == to ? (at - 1, false) : (at + 1, true) }
            return at == from ? (at + 1, true) : (at - 1, false)
        }
    }

    /// A thumbnail's size: a canvas `w` × `h` fitted in a square `most` a
    /// side, its shape kept, at least a pixel each way.
    public static func thumbSize(_ w: Int, _ h: Int, most: Int) -> (Int, Int) {
        let scale = min(Double(most) / Double(w), Double(most) / Double(h))
        return (max(1, Int((Double(w) * scale).rounded())), max(1, Int((Double(h) * scale).rounded())))
    }
}
