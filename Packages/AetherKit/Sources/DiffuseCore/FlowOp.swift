import CoreGraphics
import Foundation

/// Every edit to a flow, as a value: encoded in the shape proton-diffuse's
/// `Op` reads (`{"op": "place", "id": "5", "at": [408, 16]}`). A gesture is
/// a batch, applied whole or not at all, and is one undo step.
public enum FlowOp: Sendable, Equatable {
    case add(type: String, at: CGPoint, values: [String: JSONValue] = [:])
    case remove(ids: [String])
    case place(id: String, at: CGPoint)
    /// `.null` takes the value away, back to the catalogue's default.
    case set(id: String, name: String, value: JSONValue)
    case connect(from: String, to: String)
    case disconnect(to: String)
    case seed(id: String, mode: SeedMode)
    case bypass(id: String, on: Bool)
    case duplicate(ids: [String], by: CGSize)
    case note(String?)
    case outputs(String?)
}

extension FlowOp: Encodable {
    private enum Key: String, CodingKey {
        case op, type, at, values, ids, id, name, value, from, to, mode, on, by, text, path
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        // The core rounds nothing; whole points keep files tidy.
        func point(_ p: CGPoint) -> [Double] { [p.x.rounded(), p.y.rounded()] }
        switch self {
        case let .add(type, at, values):
            try c.encode("add", forKey: .op)
            try c.encode(type, forKey: .type)
            try c.encode(point(at), forKey: .at)
            try c.encode(values, forKey: .values)
        case let .remove(ids):
            try c.encode("remove", forKey: .op)
            try c.encode(ids, forKey: .ids)
        case let .place(id, at):
            try c.encode("place", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(point(at), forKey: .at)
        case let .set(id, name, value):
            try c.encode("set", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)
        case let .connect(from, to):
            try c.encode("connect", forKey: .op)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case let .disconnect(to):
            try c.encode("disconnect", forKey: .op)
            try c.encode(to, forKey: .to)
        case let .seed(id, mode):
            try c.encode("seed", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(mode, forKey: .mode)
        case let .bypass(id, on):
            try c.encode("bypass", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(on, forKey: .on)
        case let .duplicate(ids, by):
            try c.encode("duplicate", forKey: .op)
            try c.encode(ids, forKey: .ids)
            try c.encode([by.width.rounded(), by.height.rounded()], forKey: .by)
        case let .note(text):
            try c.encode("note", forKey: .op)
            try c.encodeIfPresent(text, forKey: .text)
        case let .outputs(path):
            try c.encode("outputs", forKey: .op)
            try c.encodeIfPresent(path, forKey: .path)
        }
    }
}
