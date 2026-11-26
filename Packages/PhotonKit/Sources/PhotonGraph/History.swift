import Foundation

/// The project's one history: every step of every document, in the order
/// they were made, and the project's own steps among them. ⌘Z walks the
/// steps of the document on screen (§6.4, rule 5).
public struct History: Sendable {
    public struct Entry: Sendable {
        public enum Kind: Sendable {
            /// A step in a document's own history, undone by its core, and
            /// the project change made with it.
            case document(String, label: String, attached: (tx: Transaction, inverse: Transaction)?)
            /// A project change on its own, and how to put it back.
            case project(Transaction, inverse: Transaction)
        }

        public let kind: Kind
        /// Part of the document as last saved: a step made before the save
        /// and not undone since.
        public internal(set) var saved = false

        public var document: String? {
            switch kind {
            case .document(let path, _, _): path
            case .project(let tx, _): tx.document
            }
        }

        public var label: String {
            switch kind {
            case .document(_, let label, _): label
            case .project(let tx, _): tx.label
            }
        }
    }

    public private(set) var done: [Entry] = []
    public private(set) var undone: [Entry] = []
    /// The most steps kept, oldest let go first.
    static let most = 10_000

    /// A new step: what was undone in its document can't be redone now.
    mutating func made(_ kind: Entry.Kind) {
        let entry = Entry(kind: kind)
        undone.removeAll { $0.document == entry.document }
        done.append(entry)
        if done.count > Self.most { done.removeFirst(done.count - Self.most) }
    }

    mutating func takeDone(in document: String?) -> Entry? {
        done.lastIndex { $0.document == document }.map { done.remove(at: $0) }
    }

    mutating func takeUndone(in document: String?) -> Entry? {
        undone.lastIndex { $0.document == document }.map { undone.remove(at: $0) }
    }

    mutating func undid(_ entry: Entry) {
        undone.append(entry)
    }

    mutating func redid(_ entry: Entry) {
        done.append(entry)
    }

    /// The document saved: what's done is in the file, what's undone isn't.
    mutating func markSaved(_ document: String) {
        for i in done.indices where done[i].document == document { done[i].saved = true }
        for i in undone.indices where undone[i].document == document { undone[i].saved = false }
    }

    /// What to change for the project to match the document as saved, when
    /// it's let go unsaved: the project changes made with steps since the
    /// save, to take back (newest first), and those made with saved steps
    /// undone since, to make again (oldest first).
    func unsaved(_ document: String) -> (takeBack: [Transaction], makeAgain: [Transaction]) {
        func attached(_ entry: Entry) -> (tx: Transaction, inverse: Transaction)? {
            if case let .document(_, _, attached) = entry.kind { return attached }
            return nil
        }
        let takeBack = done.reversed().filter { $0.document == document && !$0.saved }.compactMap { attached($0)?.inverse }
        let makeAgain = undone.reversed().filter { $0.document == document && $0.saved }.compactMap { attached($0)?.tx }
        return (takeBack, makeAgain)
    }

    mutating func forget(_ document: String) {
        done.removeAll { $0.document == document }
        undone.removeAll { $0.document == document }
    }

    /// A document moved: its steps go with it.
    mutating func move(_ document: String, to path: String) {
        func moved(_ entry: Entry) -> Entry {
            switch entry.kind {
            case let .document(old, label, attached) where old == document:
                return Entry(kind: .document(path, label: label, attached: attached.map { (Self.moved($0.tx, to: path), Self.moved($0.inverse, to: path)) }), saved: entry.saved)
            case let .project(tx, inverse) where tx.document == document:
                return Entry(kind: .project(Self.moved(tx, to: path), inverse: Self.moved(inverse, to: path)), saved: entry.saved)
            default:
                return entry
            }
        }
        done = done.map(moved)
        undone = undone.map(moved)
    }

    private static func moved(_ tx: Transaction, to path: String) -> Transaction {
        var tx = tx
        tx.document = path
        return tx
    }
}
