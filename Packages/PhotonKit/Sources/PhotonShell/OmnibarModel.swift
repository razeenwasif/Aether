import Foundation
import Observation

/// One row of the omnibar: something to do, and where it belongs.
public struct OmniItem: Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        /// What applies to the workspace on screen and its selection.
        case here = "Here"
        case actions = "Actions"
        case assets = "Assets"
        case goTo = "Go to"
    }

    public let id: String
    public let group: Group
    public let title: String
    /// A shortcut, or what it does: "⌘4", "Place as a layer · Diffuse v3".
    public let detail: String?
    /// An asset row's live dot.
    public let live: Bool
    /// Shown only once something is typed: there are many (nodes to add).
    public let onlyWhenAsked: Bool
    public let run: @MainActor () -> Void

    public init(_ group: Group, _ title: String, detail: String? = nil, live: Bool = false, onlyWhenAsked: Bool = false, id: String? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id ?? "\(group.rawValue):\(title)"
        self.group = group
        self.title = title
        self.detail = detail
        self.live = live
        self.onlyWhenAsked = onlyWhenAsked
        self.run = run
    }
}

/// The omnibar (⌘K): tools, actions, assets and Go to in one list, the
/// workspace's own first; ⇥ narrows it to one group, and on.
@MainActor
@Observable
public final class OmnibarModel {
    public enum Scope: CaseIterable, Sendable {
        case all, here, actions, assets, goTo

        public var title: String {
            switch self {
            case .all: "Everything"
            case .here: "Here"
            case .actions: "Actions"
            case .assets: "Assets"
            case .goTo: "Go to"
            }
        }

        var group: OmniItem.Group? {
            switch self {
            case .all: nil
            case .here: .here
            case .actions: .actions
            case .assets: .assets
            case .goTo: .goTo
            }
        }
    }

    public var isOpen = false
    public var query = "" {
        didSet { selected = 0 }
    }
    public var scope: Scope = .all {
        didSet { selected = 0 }
    }
    /// Which result ↩ runs, once there's a choice (see `choosing`).
    public var selected = 0
    /// Whether ↑↓ have moved the choice since it opened.
    public private(set) var moved = false

    /// Whether a row is chosen for ↩: once something is typed or ↑↓ have
    /// moved. Until then ↩ does nothing, so a key pressed too soon never
    /// runs the top row (Generate, in Diffuse).
    public var choosing: Bool { moved || !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The most results shown.
    static let most = 60

    /// What it offers, taken once as it opens, each title's letters ready
    /// to match: typing only scores them (§7a).
    @ObservationIgnored private var offered: [(item: OmniItem, letters: [Character])] = []
    @ObservationIgnored private var last: (query: String, scope: Scope, offering: Int, results: [OmniItem])?
    /// Bumped when what it offers changes, so the list is drawn again.
    public private(set) var offering = 0

    public init() {}

    /// Open, offering `items`.
    public func open(with items: [OmniItem]) {
        offer(items)
        query = ""
        scope = .all
        moved = false
        isOpen = true
    }

    /// What it offers from now on.
    public func offer(_ items: [OmniItem]) {
        offered = items.map { ($0, Array($0.title.lowercased())) }
        last = nil
        offering += 1
    }

    public func close() {
        isOpen = false
    }


    /// ⇥: the next scope; ⇧⇥ the one before.
    public func cycleScope(back: Bool = false) {
        let all = Scope.allCases
        let i = all.firstIndex(of: scope) ?? 0
        scope = all[(i + (back ? all.count - 1 : 1)) % all.count]
    }

    public func move(by step: Int, in count: Int) {
        guard count > 0 else { return }
        // The first ↓ chooses the top row; the first ↑ the bottom one.
        selected = moved || !query.isEmpty ? (selected + step + count) % count : (step > 0 ? 0 : count - 1)
        moved = true
    }

    /// What matches the query in the scope: by group with nothing typed,
    /// best match first with something typed.
    public var results: [OmniItem] {
        if let last, last.query == query, last.scope == scope, last.offering == offering { return last.results }
        let found = Self.results(of: offered, query: query, scope: scope)
        last = (query, scope, offering, found)
        return found
    }

    /// `results`, for `items` offered now; for tests.
    func results(from items: [OmniItem]) -> [OmniItem] {
        Self.results(of: items.map { ($0, Array($0.title.lowercased())) }, query: query, scope: scope)
    }

    private static func results(of offered: [(item: OmniItem, letters: [Character])], query: String, scope: Scope) -> [OmniItem] {
        let order = OmniItem.Group.allCases
        let scoped = offered.filter { scope.group == nil || $0.item.group == scope.group }
        let typed = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !typed.isEmpty else {
            let shown = scoped.map(\.item).filter { !$0.onlyWhenAsked }
            return Array(shown.enumerated().sorted {
                let (a, b) = (order.firstIndex(of: $0.element.group)!, order.firstIndex(of: $1.element.group)!)
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element).prefix(most))
        }
        let scored = scoped.compactMap { o in score(o.letters, typed).map { (o.item, $0) } }
        return Array(scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return order.firstIndex(of: $0.0.group)! < order.firstIndex(of: $1.0.group)!
        }.map(\.0).prefix(most))
    }

    static func score(_ title: String, _ query: String) -> Int? {
        score(Array(title.lowercased()), Array(query.lowercased().filter { !$0.isWhitespace }))
    }

    /// How well the letters `q` match the title's `t`, both lowercased: in
    /// order, scored up for a start, a word's start and letters together;
    /// `nil` when they aren't all there.
    static func score(_ t: [Character], _ q: [Character]) -> Int? {
        guard !q.isEmpty else { return 0 }
        var score = 0
        var at = 0
        var last = -2
        for c in q {
            guard let found = t[at...].firstIndex(of: c) else { return nil }
            let wordStart = found == 0 || !t[found - 1].isLetter && !t[found - 1].isNumber
            score += 1 + (wordStart ? 8 : 0) + (found == last + 1 ? 5 : 0) + (found == 0 ? 10 : 0)
            last = found
            at = found + 1
        }
        // Shorter titles for the same letters read as closer.
        return score * 100 - t.count
    }
}
