import DiffuseBridge
import Foundation
import Observation

/// What made a picture: its sampler's settings, its checkpoint and prompts,
/// read from the graph forge wrote into the PNG.
public struct Made: Codable, Sendable, Equatable {
    public var seed: UInt64?
    public var steps: Int?
    public var cfg: Double?
    public var sampler: String?
    public var scheduler: String?
    public var denoise: Double?
    public var checkpoint: String?
    public var prompt: String?
    public var negative: String?
}

/// A PNG's head: its size, and the graph that made it when forge wrote one.
public struct PictureHead: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// The graph, as the JSON a run sends.
    public var graphJSON: String?
    public var made: Made?

    /// Read through the core, which reads the head and never the pixels.
    public static func read(_ url: URL) -> PictureHead? {
        guard let json = pngHead(path: url.path),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        let graph = object["graph"].flatMap { $0 is NSNull ? nil : $0 }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
        let made = object["made"].flatMap { $0 is NSNull ? nil : $0 }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(Made.self, from: $0) }
        return PictureHead(width: object["width"] as? Int ?? 0, height: object["height"] as? Int ?? 0, graphJSON: graph, made: made)
    }
}

/// One picture in the gallery.
public struct GalleryPicture: Identifiable, Hashable, Sendable {
    public var url: URL
    /// The flow that made it: the folder it is in, under `outputs/`.
    public var flow: String
    public var modified: Date
    public var id: URL { url }
}

/// The pictures runs have made, newest first, filtered by flow. Outputs are
/// found under each root's `outputs/<flow name>/`, as Proton keeps them.
@MainActor
@Observable
public final class Gallery {
    public private(set) var pictures: [GalleryPicture] = []
    public private(set) var heads: [URL: PictureHead] = [:]
    public private(set) var roots: [URL] = []
    public private(set) var scanned = false
    /// The flow shown, or every flow when `nil`.
    public var filter: String?
    /// The pictures chosen: one with a press, more with ⌘-press.
    public private(set) var picked: Set<URL> = []
    /// The one whose detail the inspector shows: the last pressed.
    public private(set) var chosen: URL?

    public init() {}

    public var flows: [String] { Array(Set(pictures.map(\.flow))).sorted() }

    public var shown: [GalleryPicture] {
        guard let filter else { return pictures }
        return pictures.filter { $0.flow == filter }
    }

    public var chosenPicture: GalleryPicture? { chosen.flatMap { url in pictures.first { $0.url == url } } }

    /// Choose `url`, alone or, `adding`, as one more (pressed again, it is
    /// taken away).
    public func pick(_ url: URL, adding: Bool = false) {
        if adding {
            if picked.remove(url) == nil { picked.insert(url); chosen = url }
            else if chosen == url { chosen = picked.first }
        } else {
            picked = [url]
            chosen = url
        }
    }

    public func clearPicks() {
        picked = []
        chosen = nil
    }

    /// Let go of every picture and head read: the gallery shut.
    public func forget() {
        pictures = []
        heads = [:]
        scanned = false
        clearPicks()
    }

    /// Look through `roots` again for pictures.
    public func refresh(roots: [URL]) async {
        self.roots = roots
        let found = await Task.detached { Gallery.scan(roots) }.value
        pictures = found
        scanned = true
        let present = Set(found.map(\.url))
        picked.formIntersection(present)
        if let chosen, !present.contains(chosen) { self.chosen = picked.first }
        if let filter, !found.contains(where: { $0.flow == filter }) { self.filter = nil }
    }

    /// The head of `url`, read once.
    public func head(for url: URL) async -> PictureHead? {
        if let head = heads[url] { return head }
        let head = await Task.detached { PictureHead.read(url) }.value
        heads[url] = head
        return head
    }

    /// Move pictures to the Trash, as Proton does: never deleted outright.
    /// Answers how many could not be moved.
    @discardableResult
    public func trash(_ urls: Set<URL>, mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int {
        var failed = 0
        for url in urls {
            if (try? mover(url)) == nil { failed += 1; continue }
            pictures.removeAll { $0.url == url }
            heads[url] = nil
            picked.remove(url)
        }
        if let chosen, !picked.contains(chosen) { self.chosen = picked.first }
        return failed
    }

    nonisolated static func scan(_ roots: [URL]) -> [GalleryPicture] {
        var seen = Set<URL>()
        var found: [GalleryPicture] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            let outputs = root.appending(path: "outputs", directoryHint: .isDirectory)
            guard let walk = FileManager.default.enumerator(at: outputs, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where url.pathExtension.lowercased() == "png" {
                let resolved = url.resolvingSymlinksInPath()
                guard seen.insert(resolved).inserted else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                found.append(GalleryPicture(
                    url: url,
                    flow: url.deletingLastPathComponent().lastPathComponent,
                    modified: values?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }
}

/// Where a run's pictures go and what they are called: Proton's
/// `<prefix>_<nnnn>.png`, numbered on from the highest already there.
public enum OutputNaming {
    public static func next(in folder: URL, prefix: String) -> URL {
        let safe = prefix.isEmpty ? "image" : prefix.replacingOccurrences(of: "/", with: "-")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let taken = names.compactMap { name -> Int? in
            guard name.hasPrefix(safe + "_"), name.hasSuffix(".png") else { return nil }
            return Int(name.dropFirst(safe.count + 1).dropLast(4))
        }
        let number = (taken.max() ?? 0) + 1
        return folder.appending(path: "\(safe)_\(String(format: "%04d", number)).png")
    }
}
